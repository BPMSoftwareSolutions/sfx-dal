using System.Collections.Immutable;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Microsoft.Data.SqlClient;

namespace SFX.Semantics.Cli
{
    /// <summary>
    /// Read-only semantic object tooling.
    ///
    ///   sfx-semantics read &lt;capability-id&gt; [--estate N] [--save-source file]   live read, prints the inspection view
    ///   sfx-semantics inspect --source file                                    offline projection of a saved read
    ///   sfx-semantics verify [--capability id] [--receipt file]                the slice acceptance checks
    ///
    /// Saved sources contain the full document; keep them out of the repository.
    /// </summary>
    internal static class Program
    {
        private static readonly JsonSerializerOptions SourceFileOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            Converters = { new JsonStringEnumConverter() },
        };

        private static async Task<int> Main(string[] args)
        {
            try
            {
                return args.FirstOrDefault() switch
                {
                    "read" when args.Length >= 2 => await ReadAsync(args[1], Option(args, "--estate"), Option(args, "--save-source")),
                    "inspect" when Option(args, "--source") is { } source => Inspect(source),
                    "verify" => await VerifyAsync(Option(args, "--capability") ?? "ui-page-landing", Option(args, "--receipt")),
                    _ => Usage(),
                };
            }
            catch (SemanticReadException exception)
            {
                Console.Error.WriteLine("read refused: " + exception.Message);
                return 1;
            }
            catch (SqlException exception)
            {
                // SQL messages from the readers are named refusals or engine errors; connection details are never printed.
                Console.Error.WriteLine("sql error " + exception.Number + ": " + exception.Message);
                return 1;
            }
        }

        private static int Usage()
        {
            Console.Error.WriteLine("usage: sfx-semantics read <capability-id> [--estate N] [--save-source file]");
            Console.Error.WriteLine("       sfx-semantics inspect --source file");
            Console.Error.WriteLine("       sfx-semantics verify [--capability id] [--receipt file]");
            return 64;
        }

        private static string? Option(string[] args, string name)
        {
            int index = Array.IndexOf(args, name);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }

        private static async Task<int> ReadAsync(string capabilityId, string? estate, string? saveSource)
        {
            SemanticReadClient client = SemanticReadClient.FromEnvironment();
            SemanticRead read = await client.ReadCapabilitySourceAsync(capabilityId, estate == null ? null : long.Parse(estate, System.Globalization.CultureInfo.InvariantCulture));
            if (saveSource != null)
            {
                File.WriteAllText(saveSource, JsonSerializer.Serialize(read, SourceFileOptions), new UTF8Encoding(false));
            }

            CapabilitySnapshot snapshot = CapabilitySnapshot.Project(read.Source, read.Capture);
            Console.WriteLine(snapshot.ToInspectionJson());
            return snapshot.Availability == SemanticAvailability.ContractMismatch ? 3 : 0;
        }

        private static int Inspect(string sourcePath)
        {
            SemanticRead read = JsonSerializer.Deserialize<SemanticRead>(File.ReadAllText(sourcePath), SourceFileOptions)
                ?? throw new InvalidDataException("The saved source is empty.");
            CapabilitySnapshot snapshot = CapabilitySnapshot.Project(read.Source, read.Capture);
            Console.WriteLine(snapshot.ToInspectionJson());
            return snapshot.Availability == SemanticAvailability.ContractMismatch ? 3 : 0;
        }

        private static async Task<int> VerifyAsync(string capabilityId, string? receiptPath)
        {
            SemanticReadClient client = SemanticReadClient.FromEnvironment();
            var checks = new List<Check>();
            string semanticRoot = FindSemanticRoot();

            // Reader identity, before any read.
            (string? readerUtf16Before, string? readerUtf8) = await client.ReadDefinitionDigestsAsync(CapabilityProjectionContract.Procedure);
            string? researchUtf8 = ResearchReaderDigest(semanticRoot);
            checks.Add(new Check("reader-identity", "The read goes through the installed reader whose body the research receipt recorded.",
                readerUtf8 != null && readerUtf8 == researchUtf8,
                "installed UTF-8 SHA-256 " + (readerUtf8 ?? "not visible") + "; research receipt " + (researchUtf8 ?? "not found")));

            // Two independent reads, each on its own connection and rolled-back SNAPSHOT transaction.
            SemanticRead readA = await client.ReadCapabilitySourceAsync(capabilityId);
            CapabilitySnapshot a = CapabilitySnapshot.Project(readA.Source, readA.Capture);
            SemanticRead readB = await client.ReadCapabilitySourceAsync(capabilityId, long.Parse(readA.Source.Basis!, System.Globalization.CultureInfo.InvariantCulture));
            CapabilitySnapshot b = CapabilitySnapshot.Project(readB.Source, readB.Capture);
            (string? readerUtf16After, _) = await client.ReadDefinitionDigestsAsync(CapabilityProjectionContract.Procedure);

            checks.Add(new Check("read-through-procedure", "The capability is read through its current procedure in document mode.",
                a.Availability == SemanticAvailability.Present && readA.Source.RowResultSets == 0 && readA.Source.DocumentText != null
                    && a.Provenance.Procedure == CapabilityProjectionContract.Procedure && readA.Capture.ReaderDefinitionDigest == readerUtf16Before,
                a.Provenance.Procedure + " availability " + a.Availability + ", row result sets " + readA.Source.RowResultSets
                    + ", emit bound as " + Argument(a, "emit") + ", capability_version_pk " + Argument(a, "capability_version_pk")));

            int errors = a.Diagnostics.Count(diagnostic => diagnostic.Severity == SemanticSeverity.Error);
            checks.Add(new Check("faithful-projection", "The document conforms to the contract: no projection errors.",
                errors == 0, errors + " error(s); " + Summarize(a.Diagnostics)));

            Capability? root = a.Capability;
            checks.Add(new Check("source-identity", "The snapshot carries the requested identity (ordinal) and the basis the reader resolved.",
                a.Identity != null && a.Identity.DeclaredId == capabilityId && root != null
                    && root.EstateModelPk?.ToString(System.Globalization.CultureInfo.InvariantCulture) == readA.Source.Basis,
                a.Identity == null ? "no identity" : a.Identity.Namespace + "/" + a.Identity.Kind + "/" + a.Identity.DeclaredId + " revision locator " + a.Identity.Revision
                    + "; bound basis " + readA.Source.Basis + ", reader-reported basis " + root?.EstateModelPk));

            string? reconstructed = a.ReconstructSourceDocument();
            string? difference = "no document";
            bool lossless = reconstructed != null && SemanticJsonEquivalence.Equivalent(readA.Source.DocumentText!, reconstructed, out difference);

            checks.Add(new Check("lossless", "The source document is rebuilt from the snapshot alone: typed values plus retained sections, markers and unmapped fields.",
                lossless, lossless ? "semantically equal to the source document" : "first difference: " + (difference ?? "no document")));

            var typed = a.Sections.Where(section => section.Disposition == SemanticSectionDisposition.Typed).ToList();
            bool accountedRows = typed.All(section => section.EntityCount + section.MarkerCount + section.UnprojectedCount == section.RowCount);
            checks.Add(new Check("unknown-retained", "Every expected section is present; untyped sections are retained verbatim; every typed row is an entity, a declared marker or retained.",
                a.Sections.Length == CapabilityProjectionContract.ExpectedSections.Length && accountedRows
                    && a.Sections.All(section => section.Disposition != SemanticSectionDisposition.Unexpected),
                typed.Count + " typed and " + (a.Sections.Length - typed.Count) + " retained of " + CapabilityProjectionContract.ExpectedSections.Length + " expected sections; "
                    + typed.Sum(section => section.MarkerCount) + " marker row(s) kept out of entity collections"));

            checks.Add(new Check("source-census", "Entity collections agree with the counts the reader's own summary reports.",
                root != null && root.Scenarios == a.Scenarios.Length && root.Operations == a.ExecutionOperations.Length && root.Providers == a.Providers.Length
                    && root.Contracts == a.Contracts.Select(contract => contract.ContractVersionPk).Where(pk => pk != null).Distinct().Count()
                    && root.Ports == a.Ports.Select(port => port.PortPk).Where(pk => pk != null).Distinct().Count(),
                root == null ? "no root" : "summary scenarios/operations/providers/contracts/ports " + root.Scenarios + "/" + root.Operations + "/" + root.Providers + "/" + root.Contracts + "/" + root.Ports
                    + "; entities " + a.Scenarios.Length + "/" + a.ExecutionOperations.Length + "/" + a.Providers.Length + "/" + a.Contracts.Length + "/" + a.Ports.Length));

            Dictionary<string, int> resolutions = Resolutions(a);
            checks.Add(new Check("references", "Declared exact-key references resolve inside the snapshot; nothing is fetched implicitly.",
                resolutions.GetValueOrDefault("Dangling") == 0,
                string.Join(", ", resolutions.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + " " + pair.Value))));

            checks.Add(new Check("immutable", "Generated public types expose no mutable state: snapshot properties are get-only, entity properties are init-only, collections are immutable.",
                ImmutabilityViolations().Count == 0,
                ImmutabilityViolations().Count == 0 ? "checked " + SemanticObjectTypes().Count() + " semantic object types (" + string.Join(", ", SemanticObjectTypes().Select(type => type.Name).Where(name => name.StartsWith("Semantic", StringComparison.Ordinal) == false)) + " and the Semantic* runtime records)" : string.Join("; ", ImmutabilityViolations())));

            CapabilitySnapshot again = CapabilitySnapshot.Project(readA.Source, readA.Capture);
            CapabilitySnapshot otherCapture = CapabilitySnapshot.Project(readA.Source, readA.Capture with { CapturedAtUtc = DateTimeOffset.UnixEpoch, ElapsedMilliseconds = 0 });
            checks.Add(new Check("deterministic-projection", "Projecting the same source again yields the same digest and view; capture time and duration are not part of the digest.",
                a.ProjectionDigest != null && again.ProjectionDigest == a.ProjectionDigest && again.ToInspectionJson() == a.ToInspectionJson() && otherCapture.ProjectionDigest == a.ProjectionDigest,
                "projection digest " + a.ProjectionDigest));

            checks.Add(new Check("reproduced-read", "An independent second read of the same basis reproduces the source document and the projection digest.",
                b.ProjectionDigest == a.ProjectionDigest && b.Provenance.DocumentSha256 == a.Provenance.DocumentSha256,
                "document SHA-256 " + a.Provenance.DocumentSha256 + " / " + b.Provenance.DocumentSha256 + "; projection " + b.ProjectionDigest));

            // Negative fixtures: an unknown identity and a case-changed identity are typed absences, not errors or partial objects.
            const string absentId = "sfx-semantic-slice-absent-probe";
            SemanticRead absentRead = await client.ReadCapabilitySourceAsync(absentId);
            CapabilitySnapshot absent = CapabilitySnapshot.Project(absentRead.Source, absentRead.Capture);
            string caseId = capabilityId.ToUpperInvariant();
            SemanticRead caseRead = await client.ReadCapabilitySourceAsync(caseId);
            CapabilitySnapshot caseChanged = CapabilitySnapshot.Project(caseRead.Source, caseRead.Capture);
            checks.Add(new Check("absence-is-typed", "An unknown capability and a case-changed identity project as Absent with the reader's declared refusal.",
                absent.Availability == SemanticAvailability.Absent && absent.Refusal?.Code == "CAPABILITY_NOT_FOUND" && absent.Capability == null
                    && (caseId == capabilityId || (caseChanged.Availability == SemanticAvailability.Absent && caseChanged.Refusal?.Code == "CAPABILITY_NOT_FOUND")),
                absentId + ": " + absent.Availability + "/" + absent.Refusal?.Code + "; " + caseId + ": " + caseChanged.Availability + "/" + caseChanged.Refusal?.Code));

            SemanticRead[] reads = { readA, readB, absentRead, caseRead };
            checks.Add(new Check("estate-unchanged", "Every read generated zero log records in the estate database and was rolled back; the reader body is unchanged.",
                reads.All(read => read.Capture.DatabaseLogRecords == 0 && read.Capture.TransactionOutcome == "ROLLED_BACK") && readerUtf16Before == readerUtf16After,
                "log records " + string.Join("/", reads.Select(read => read.Capture.DatabaseLogRecords?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "unobservable"))
                    + "; outcomes " + string.Join("/", reads.Select(read => read.Capture.TransactionOutcome)) + "; reader digest " + (readerUtf16Before == readerUtf16After ? "unchanged" : "CHANGED")));

            (bool bound, string boundEvidence) = GeneratedCodeBound(semanticRoot);
            checks.Add(new Check("generated-by-codelightly", "The compiled projection is the CodeLightly output recorded in the manifest for this contract.", bound, boundEvidence));

            bool passed = checks.All(check => check.Passed);
            foreach (Check check in checks)
            {
                Console.WriteLine((check.Passed ? "PASS " : "FAIL ") + check.Id + ": " + check.Evidence);
            }

            Console.WriteLine(passed ? "All " + checks.Count + " checks passed." : checks.Count(check => check.Passed == false) + " check(s) failed.");
            if (receiptPath != null)
            {
                WriteReceipt(receiptPath, capabilityId, a, readA, readB, absent, caseChanged, readerUtf16Before, readerUtf8, resolutions, checks, passed);
                Console.WriteLine("Receipt saved: " + Path.GetFullPath(receiptPath));
            }

            return passed ? 0 : 2;
        }

        private static string Argument(CapabilitySnapshot snapshot, string parameter)
        {
            SemanticBoundArgument? argument = snapshot.Provenance.Arguments.FirstOrDefault(candidate => candidate.Parameter == parameter);
            return argument == null ? "undeclared" : argument.Binding + (argument.Value == null ? string.Empty : " " + argument.Value);
        }

        private static string Summarize(ImmutableArray<SemanticDiagnostic> diagnostics) =>
            diagnostics.Length == 0 ? "no diagnostics" : string.Join(", ", diagnostics.GroupBy(diagnostic => diagnostic.Severity + " " + diagnostic.Code).OrderBy(group => group.Key, StringComparer.Ordinal).Select(group => group.Key + " x" + group.Count()));

        private static Dictionary<string, int> Resolutions(CapabilitySnapshot snapshot)
        {
            var states = new List<SemanticResolutionState>();
            states.AddRange(snapshot.ExecutionOperations.Select(operation => snapshot.ResolveScenario(operation).State));
            states.AddRange(snapshot.ExecutionOperations.Select(operation => snapshot.ResolvePort(operation).State));
            states.AddRange(snapshot.Contracts.Select(contract => snapshot.ResolveScenario(contract).State));
            states.AddRange(snapshot.Bindings.Select(binding => snapshot.ResolveProvider(binding).State));
            return states.GroupBy(state => state.ToString()).ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        }

        // The semantic object model: every exported class except exceptions (whose mutable members are inherited
        // from System.Exception) and the read client.
        private static IEnumerable<Type> SemanticObjectTypes() => typeof(CapabilitySnapshot).Assembly.GetExportedTypes()
            .Where(type => type.Namespace == "SFX.Semantics" && type.IsClass && type.IsAbstract == false
                && typeof(Exception).IsAssignableFrom(type) == false && type != typeof(SemanticReadClient));

        private static List<string> ImmutabilityViolations()
        {
            var violations = new List<string>();
            Type[] mutable = { typeof(List<>), typeof(Dictionary<,>), typeof(HashSet<>), typeof(System.Collections.ArrayList) };
            foreach (Type type in SemanticObjectTypes())
            {
                foreach (PropertyInfo property in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
                {
                    MethodInfo? setter = property.GetSetMethod(nonPublic: false);
                    bool initOnly = setter != null && setter.ReturnParameter.GetRequiredCustomModifiers().Contains(typeof(System.Runtime.CompilerServices.IsExternalInit));
                    if (setter != null && initOnly == false)
                    {
                        violations.Add(type.Name + "." + property.Name + " has a public setter");
                    }

                    Type propertyType = property.PropertyType;
                    if (propertyType.IsArray || (propertyType.IsGenericType && mutable.Contains(propertyType.GetGenericTypeDefinition())) || mutable.Contains(propertyType))
                    {
                        violations.Add(type.Name + "." + property.Name + " exposes a mutable collection");
                    }
                }
            }

            return violations;
        }

        private static (bool Bound, string Evidence) GeneratedCodeBound(string semanticRoot)
        {
            string generated = Path.Combine(semanticRoot, "SFX.Semantics", "Generated");
            string manifestPath = Path.Combine(generated, "semantic-projection-manifest.v1.json");
            if (File.Exists(manifestPath) == false)
            {
                return (false, "manifest not found");
            }

            JsonNode manifest = JsonNode.Parse(File.ReadAllText(manifestPath))!;
            var mismatches = new List<string>();
            int artifacts = 0;
            foreach (JsonNode? artifact in manifest["artifacts"]!.AsArray())
            {
                artifacts++;
                string path = Path.Combine(generated, (string)artifact!["path"]!);
                string actual = File.Exists(path) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant() : "missing";
                if (actual != (string)artifact["sha256"]!)
                {
                    mismatches.Add((string)artifact["path"]!);
                }
            }

            string? contractDigest = manifest["contracts"]!.AsArray().Select(contract => (string?)contract!["digest"]).FirstOrDefault(digest => digest == CapabilityProjectionContract.Digest);
            string generator = (string)manifest["generator"]!["emitter"]! + " " + (string?)manifest["generator"]!["sourceDigest"];
            bool bound = mismatches.Count == 0 && contractDigest != null;
            return (bound, artifacts + " artifact hash(es) " + (mismatches.Count == 0 ? "match" : "differ: " + string.Join(", ", mismatches))
                + "; compiled contract digest " + CapabilityProjectionContract.Digest + (contractDigest == null ? " NOT in manifest" : " in manifest") + "; generator " + generator);
        }

        private static string? ResearchReaderDigest(string semanticRoot)
        {
            string path = Path.Combine(Path.GetDirectoryName(semanticRoot)!, "verification", "2026-10-09-semantic-readers.json");
            if (File.Exists(path) == false)
            {
                return null;
            }

            JsonNode receipt = JsonNode.Parse(File.ReadAllText(path))!;
            return receipt["procedures"]!.AsArray()
                .Where(procedure => (string?)procedure!["name"] == "analysis.read_capability_details")
                .Select(procedure => (string?)procedure!["definitionUtf8Sha256"])
                .FirstOrDefault();
        }

        private static string FindSemanticRoot()
        {
            for (DirectoryInfo? directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
            {
                if (File.Exists(Path.Combine(directory.FullName, "semantic-projection.config.json")))
                {
                    return directory.FullName;
                }
            }

            throw new DirectoryNotFoundException("Run the verifier from within the semantic/ tree.");
        }

        private static void WriteReceipt(string path, string capabilityId, CapabilitySnapshot a, SemanticRead readA, SemanticRead readB, CapabilitySnapshot absent, CapabilitySnapshot caseChanged,
            string? readerUtf16, string? readerUtf8, Dictionary<string, int> resolutions, List<Check> checks, bool passed)
        {
            JsonObject Read(string label, SemanticRead read, CapabilitySnapshot snapshot) => new JsonObject
            {
                ["label"] = label,
                ["identity"] = read.Source.Identity,
                ["basis"] = read.Source.Basis,
                ["availability"] = snapshot.Availability.ToString(),
                ["refusal"] = snapshot.Refusal?.Code,
                ["rowResultSets"] = read.Source.RowResultSets,
                ["documentSha256"] = snapshot.Provenance.DocumentSha256,
                ["documentUtf8Bytes"] = snapshot.Provenance.DocumentUtf8Bytes,
                ["projectionDigest"] = snapshot.ProjectionDigest,
                ["isolation"] = read.Capture.Isolation,
                ["transactionOutcome"] = read.Capture.TransactionOutcome,
                ["databaseLogRecords"] = read.Capture.DatabaseLogRecords,
                ["elapsedMilliseconds"] = read.Capture.ElapsedMilliseconds,
            };

            var sections = new JsonArray();
            foreach (SemanticSection section in a.Sections)
            {
                var item = new JsonObject { ["section"] = section.Name, ["disposition"] = section.Disposition.ToString(), ["rows"] = section.RowCount };
                if (section.Disposition == SemanticSectionDisposition.Typed)
                {
                    item["entities"] = section.EntityCount;
                    item["markers"] = section.MarkerCount;
                    item["unprojected"] = section.UnprojectedCount;
                }

                sections.Add(item);
            }

            var receipt = new JsonObject
            {
                ["schemaVersion"] = "sfx-semantic-capability-slice.v1",
                ["capturedAtUtc"] = readA.Capture.CapturedAtUtc?.ToString("O", System.Globalization.CultureInfo.InvariantCulture),
                ["claim"] = "An existing SideFX capability can be read through its current database procedure, projected by CodeLightly into a faithful immutable C# semantic object, inspected without losing source identity or unknown information, and reproduced deterministically, without changing the underlying estate.",
                ["scope"] = "One capability, four reads (two of the capability on the same basis, an unknown identity and a case-changed identity), each in its own SNAPSHOT transaction that was rolled back. Metadata, counts and digests only; no row payloads or credentials. Seven of 45 sections are typed; the rest are retained verbatim. Read fidelity only: no admission, conformance, mutation, HTTP or cross-language claim.",
                ["database"] = readA.Capture.Database,
                ["capability"] = capabilityId,
                ["identity"] = a.Identity == null ? null : new JsonObject
                {
                    ["namespace"] = a.Identity.Namespace,
                    ["kind"] = a.Identity.Kind,
                    ["declaredId"] = a.Identity.DeclaredId,
                    ["revisionLocator"] = a.Identity.Revision,
                },
                ["contract"] = new JsonObject
                {
                    ["id"] = CapabilityProjectionContract.Id,
                    ["revision"] = CapabilityProjectionContract.Revision,
                    ["authority"] = CapabilityProjectionContract.Authority,
                    ["digest"] = CapabilityProjectionContract.Digest,
                    ["generator"] = CapabilityProjectionContract.Generator,
                },
                ["reader"] = new JsonObject
                {
                    ["procedure"] = CapabilityProjectionContract.Procedure,
                    ["definitionUtf16LeSha256"] = readerUtf16,
                    ["definitionUtf8Sha256"] = readerUtf8,
                },
                ["payloadAlgorithm"] = SemanticCanonicalJson.Algorithm,
                ["reads"] = new JsonArray(Read("capability", readA, a), Read("capability-repeat", readB, CapabilitySnapshot.Project(readB.Source, readB.Capture)), Read("unknown-identity", ReadOf(absent), absent), Read("case-changed-identity", ReadOf(caseChanged), caseChanged)),
                ["sections"] = sections,
                ["unmappedFields"] = new JsonArray(a.Diagnostics.Where(diagnostic => diagnostic.Code == "UnmappedField").Select(diagnostic => (JsonNode?)(diagnostic.Section + "." + diagnostic.Field)).ToArray()),
                ["diagnostics"] = new JsonObject(a.Diagnostics.GroupBy(diagnostic => diagnostic.Severity + " " + diagnostic.Code).OrderBy(group => group.Key, StringComparer.Ordinal)
                    .Select(group => KeyValuePair.Create(group.Key, (JsonNode?)group.Count()))),
                ["references"] = new JsonObject(resolutions.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => KeyValuePair.Create(pair.Key, (JsonNode?)pair.Value))),
                ["checks"] = new JsonArray(checks.Select(check => (JsonNode?)new JsonObject
                {
                    ["id"] = check.Id,
                    ["claim"] = check.Claim,
                    ["passed"] = check.Passed,
                    ["evidence"] = check.Evidence,
                }).ToArray()),
                ["passed"] = passed,
            };

            string json = receipt.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }).Replace("\r\n", "\n") + "\n";
            File.WriteAllText(path, json, new UTF8Encoding(false));

            static SemanticRead ReadOf(CapabilitySnapshot snapshot) => new SemanticRead(
                new SemanticSource(snapshot.Provenance.Procedure, snapshot.Provenance.Arguments, null, snapshot.Provenance.RowResultSets, snapshot.Refusal),
                snapshot.Provenance.Capture);
        }

        private sealed record Check(string Id, string Claim, bool Passed, string Evidence);
    }
}
