using System.Collections.Immutable;
using System.Globalization;
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
    ///   sfx-semantics read &lt;capability-id&gt; [--estate N] [--save-source file]        live capability read, inspection view
    ///   sfx-semantics inspect --source file                                         offline capability projection
    ///   sfx-semantics verify [--capability id] [--reads N] [--receipt file]         capability slice acceptance
    ///   sfx-semantics inspect-models &lt;capability-id&gt; [--estate N] [--operation sel] [--json] [--save-source file]
    ///   sfx-semantics inspect-models --source file [--operation sel] [--json]       offline replay
    ///   sfx-semantics verify-models [--capability id] [--estate N] [--receipt file] model inspection acceptance
    ///
    /// Saved sources contain full documents; keep them out of the repository.
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
                    "read" when args.Length >= 2 => await ReadAsync(args[1], Long(Option(args, "--estate")), Option(args, "--save-source")),
                    "inspect" when Option(args, "--source") is { } source => Inspect(source),
                    "verify" => await VerifyAsync(Option(args, "--capability") ?? "ui-page-landing", Int(Option(args, "--reads")) ?? 6, Option(args, "--receipt")),
                    "inspect-models" => await InspectModelsAsync(args),
                    "verify-models" => await VerifyModelsAsync(Option(args, "--capability") ?? "request-capability-from-objective-v3", Long(Option(args, "--estate")), Option(args, "--receipt")),
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
            Console.Error.WriteLine("       sfx-semantics verify [--capability id] [--reads N] [--receipt file]");
            Console.Error.WriteLine("       sfx-semantics inspect-models <capability-id> [--estate N] [--operation label|id] [--json] [--save-source file]");
            Console.Error.WriteLine("       sfx-semantics inspect-models --source file [--operation label|id] [--json]");
            Console.Error.WriteLine("       sfx-semantics verify-models [--capability id] [--estate N] [--receipt file]");
            return 64;
        }

        private static string? Option(string[] args, string name)
        {
            int index = Array.IndexOf(args, name);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }

        private static long? Long(string? value) => value == null ? null : long.Parse(value, CultureInfo.InvariantCulture);

        private static int? Int(string? value) => value == null ? null : int.Parse(value, CultureInfo.InvariantCulture);

        // Capability slice

        private static async Task<int> ReadAsync(string capabilityId, long? estate, string? saveSource)
        {
            SemanticRead read = await SemanticReadClient.FromEnvironment().ReadCapabilitySourceAsync(capabilityId, estate);
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

        private static async Task<int> VerifyAsync(string capabilityId, int repeatedReads, string? receiptPath)
        {
            SemanticReadClient client = SemanticReadClient.FromEnvironment();
            var checks = new List<Check>();
            string semanticRoot = FindSemanticRoot();

            (string? readerUtf16Before, string? readerUtf8) = await client.ReadDefinitionDigestsAsync(CapabilityProjectionContract.Procedure);
            string? researchUtf8 = ResearchReaderDigest(semanticRoot);
            checks.Add(new Check("reader-identity", "The read goes through the installed reader whose body the research receipt recorded.",
                readerUtf8 != null && readerUtf8 == researchUtf8,
                "installed UTF-8 SHA-256 " + (readerUtf8 ?? "not visible") + "; research receipt " + (researchUtf8 ?? "not found")));

            SemanticRead readA = await client.ReadCapabilitySourceAsync(capabilityId);
            CapabilitySnapshot a = CapabilitySnapshot.Project(readA.Source, readA.Capture);
            long basis = long.Parse(readA.Source.Basis!, CultureInfo.InvariantCulture);

            checks.Add(new Check("read-through-procedure", "The capability is read through its current procedure in document mode.",
                a.Availability == SemanticAvailability.Present && readA.Source.RowResultSets == 0 && readA.Source.DocumentText != null
                    && a.Provenance.Procedure == CapabilityProjectionContract.Procedure && readA.Capture.ReaderDefinitionDigest == readerUtf16Before,
                a.Provenance.Procedure + " availability " + a.Availability + ", row result sets " + readA.Source.RowResultSets
                    + ", emit bound as " + Argument(a.Provenance, "emit") + ", capability_version_pk " + Argument(a.Provenance, "capability_version_pk")));

            int errors = a.Diagnostics.Count(diagnostic => diagnostic.Severity == SemanticSeverity.Error);
            checks.Add(new Check("faithful-projection", "The document conforms to the contract: no projection errors.", errors == 0, errors + " error(s); " + Summarize(a.Diagnostics)));

            Capability? root = a.Capability;
            checks.Add(new Check("source-identity", "The snapshot carries the requested identity (ordinal) and the reader-reported basis equals the bound basis.",
                a.Identity != null && a.Identity.DeclaredId == capabilityId && root != null && a.Diagnostics.All(diagnostic => diagnostic.Code != "BasisMismatch")
                    && root.EstateModelPk?.ToString(CultureInfo.InvariantCulture) == readA.Source.Basis,
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
                a.Sections.Length == CapabilityProjectionContract.ExpectedSections.Length && accountedRows && a.Sections.All(section => section.Disposition != SemanticSectionDisposition.Unexpected),
                typed.Count + " typed and " + (a.Sections.Length - typed.Count) + " retained of " + CapabilityProjectionContract.ExpectedSections.Length + " expected sections; "
                    + typed.Sum(section => section.MarkerCount) + " marker row(s) kept out of entity collections; " + a.Sections.Count(section => section.Unordered) + " declared order-free"));

            checks.Add(new Check("source-census", "Entity collections agree with the counts the reader's own summary reports.",
                root != null && root.Scenarios == a.Scenarios.Length && root.Operations == a.ExecutionOperations.Length && root.Providers == a.Providers.Length
                    && root.Contracts == a.Contracts.Select(contract => contract.ContractVersionPk).Where(pk => pk != null).Distinct().Count()
                    && root.Ports == a.Ports.Select(port => port.PortPk).Where(pk => pk != null).Distinct().Count(),
                root == null ? "no root" : "summary scenarios/operations/providers/contracts/ports " + root.Scenarios + "/" + root.Operations + "/" + root.Providers + "/" + root.Contracts + "/" + root.Ports
                    + "; entities " + a.Scenarios.Length + "/" + a.ExecutionOperations.Length + "/" + a.Providers.Length + "/" + a.Contracts.Length + "/" + a.Ports.Length));

            Dictionary<string, int> resolutions = Resolutions(a);
            checks.Add(new Check("references", "Declared exact-key references resolve inside the snapshot; nothing is fetched implicitly.",
                resolutions.GetValueOrDefault("Dangling") == 0 && resolutions.GetValueOrDefault("Incomplete") == 0,
                string.Join(", ", resolutions.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + " " + pair.Value))));

            checks.Add(new Check("immutable", "Generated public types expose no mutable state: snapshot properties are get-only, entity properties are init-only, collections are immutable.",
                ImmutabilityViolations().Count == 0,
                ImmutabilityViolations().Count == 0 ? "checked " + SemanticObjectTypes().Count() + " semantic object types" : string.Join("; ", ImmutabilityViolations())));

            CapabilitySnapshot again = CapabilitySnapshot.Project(readA.Source, readA.Capture);
            CapabilitySnapshot otherCapture = CapabilitySnapshot.Project(readA.Source, readA.Capture with { CapturedAtUtc = DateTimeOffset.UnixEpoch, ElapsedMilliseconds = 0 });
            checks.Add(new Check("deterministic-projection", "Projecting the same source again yields the same digest and view; capture time and duration are not part of the digest.",
                a.ProjectionDigest != null && again.ProjectionDigest == a.ProjectionDigest && again.ToInspectionJson() == a.ToInspectionJson() && otherCapture.ProjectionDigest == a.ProjectionDigest,
                "projection digest " + a.ProjectionDigest));

            checks.Add(new Check("revision-vector", "The read records what it depended on: reader body digest, the capability's selected version digest and each referenced declaration's digest.",
                a.Revision.ReaderDefinitionDigest != null && a.Revision.Dependencies.Any(dependency => dependency.Kind == "CAPABILITY_VERSION" && dependency.Digest != null),
                a.Revision.Dependencies.Length + " dependencies, " + a.Revision.Unpinned + " without a digest; revision " + a.Revision.RevisionDigest));

            // Repeated reads of one basis: same revision must mean same projection; any row-order variation must be in a declared order-free section.
            var repeated = new List<(SemanticRead Read, CapabilitySnapshot Snapshot)> { (readA, a) };
            for (int index = 1; index < Math.Max(2, repeatedReads); index++)
            {
                SemanticRead read = await client.ReadCapabilitySourceAsync(capabilityId, basis);
                repeated.Add((read, CapabilitySnapshot.Project(read.Source, read.Capture)));
            }

            (bool stable, string stability, JsonObject variation) = RepeatedReadEvidence(repeated, CapabilityProjectionContract.UnorderedSections);
            checks.Add(new Check("reproduced-read", "Independent reads of one basis that share a revision digest share a projection digest; row-order variation occurs only in declared order-free sections.",
                stable, stability));

            // Review findings, closed: each probe projects a mutated copy of read A offline.
            checks.Add(FindingCheck("basis-validated", "A bound basis that differs from the reader-reported basis is a contract mismatch, and an unregistered estate pin is refused before any read.",
                () =>
                {
                    CapabilitySnapshot mismatched = CapabilitySnapshot.Project(readA.Source with
                    {
                        Arguments = readA.Source.Arguments.Select(argument => argument.Role == "basis" ? argument with { Value = "999999" } : argument).ToImmutableArray(),
                    }, readA.Capture);
                    string? refused = null;
                    try
                    {
                        client.OpenSessionAsync(999_999_999).GetAwaiter().GetResult().DisposeAsync().AsTask().GetAwaiter().GetResult();
                    }
                    catch (SemanticReadException exception)
                    {
                        refused = exception.Message;
                    }

                    return (mismatched.Availability == SemanticAvailability.ContractMismatch && mismatched.Diagnostics.Any(diagnostic => diagnostic.Code == "BasisMismatch") && refused != null,
                        "bound 999999 vs reported " + basis + ": " + mismatched.Availability + "/" + string.Join(",", mismatched.Diagnostics.Select(diagnostic => diagnostic.Code).Distinct())
                        + "; pin 999999999: " + (refused ?? "NOT refused"));
                }));

            checks.Add(FindingCheck("refusal-validated", "A refusal never chooses its own availability: an undeclared refusal, or a refusal read through another procedure, is a contract mismatch.",
                () =>
                {
                    CapabilitySnapshot undeclared = CapabilitySnapshot.Project(readA.Source with { DocumentText = null, Refusal = new SemanticSourceRefusal(51000, "INVENTED_REFUSAL", "INVENTED_REFUSAL", SemanticAvailability.Present) }, readA.Capture);
                    CapabilitySnapshot wrongProcedure = CapabilitySnapshot.Project(readA.Source with { Procedure = "[other].[reader]", DocumentText = null, Refusal = new SemanticSourceRefusal(51000, "CAPABILITY_NOT_FOUND", "CAPABILITY_NOT_FOUND", SemanticAvailability.Absent) }, readA.Capture);
                    CapabilitySnapshot declared = CapabilitySnapshot.Project(readA.Source with { DocumentText = null, Refusal = new SemanticSourceRefusal(51000, "CAPABILITY_NOT_FOUND", "CAPABILITY_NOT_FOUND", SemanticAvailability.Present) }, readA.Capture);
                    return (undeclared.Availability == SemanticAvailability.ContractMismatch && wrongProcedure.Availability == SemanticAvailability.ContractMismatch && declared.Availability == SemanticAvailability.Absent,
                        "undeclared " + undeclared.Availability + ", wrong procedure " + wrongProcedure.Availability + ", declared refusal claiming Present " + declared.Availability);
                }));

            checks.Add(FindingCheck("incomplete-references", "A partially-null reference key is Incomplete (with a warning), not NotApplicable; an entity with a null identifying key value is a contract mismatch.",
                () =>
                {
                    JsonNode document = JsonNode.Parse(readA.Source.DocumentText!)!;
                    JsonNode? operation = document["execution_operations"]!.AsArray().FirstOrDefault(row => row!["port_id"] != null && row["port_version_pk"] != null);
                    if (operation == null)
                    {
                        return (false, "no operation with a port to mutate");
                    }

                    long? operationPk = (long?)operation["execution_operation_pk"];
                    operation["port_version_pk"] = null;
                    CapabilitySnapshot partial = CapabilitySnapshot.Project(readA.Source with { DocumentText = document.ToJsonString() }, readA.Capture);
                    SemanticResolutionState state = partial.ResolvePort(partial.ExecutionOperations.First(candidate => candidate.ExecutionOperationPk == operationPk)).State;
                    JsonNode nullKey = JsonNode.Parse(readA.Source.DocumentText!)!;
                    nullKey["execution_operations"]![0]!["execution_operation_pk"] = null;
                    CapabilitySnapshot keyless = CapabilitySnapshot.Project(readA.Source with { DocumentText = nullKey.ToJsonString() }, readA.Capture);
                    return (state == SemanticResolutionState.Incomplete && partial.Diagnostics.Any(diagnostic => diagnostic.Code == "IncompleteReference")
                            && keyless.Availability == SemanticAvailability.ContractMismatch && keyless.Diagnostics.Any(diagnostic => diagnostic.Code == "KeyIncomplete"),
                        "port_version_pk nulled: " + state + "; execution_operation_pk nulled: " + keyless.Availability + "/" + string.Join(",", keyless.Diagnostics.Where(diagnostic => diagnostic.Severity == SemanticSeverity.Error).Select(diagnostic => diagnostic.Code).Distinct()));
                }));

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

            (string? readerUtf16After, _) = await client.ReadDefinitionDigestsAsync(CapabilityProjectionContract.Procedure);
            SemanticRead[] reads = repeated.Select(pair => pair.Read).Append(absentRead).Append(caseRead).ToArray();
            checks.Add(new Check("estate-unchanged", "Every read generated zero log records in the estate database and was rolled back; the reader body is unchanged.",
                reads.All(read => read.Capture.DatabaseLogRecords == 0 && read.Capture.TransactionOutcome == "ROLLED_BACK") && readerUtf16Before == readerUtf16After,
                reads.Length + " reads; log records " + string.Join("/", reads.Select(read => read.Capture.DatabaseLogRecords?.ToString(CultureInfo.InvariantCulture) ?? "unobservable"))
                    + "; reader digest " + (readerUtf16Before == readerUtf16After ? "unchanged" : "CHANGED")));

            (bool bound, string boundEvidence) = GeneratedCodeBound(semanticRoot, CapabilityProjectionContract.Digest);
            checks.Add(new Check("generated-by-codelightly", "The compiled projection is the CodeLightly output recorded in the manifest for this contract.", bound, boundEvidence));

            bool passed = Report(checks);
            if (receiptPath != null)
            {
                var receipt = new JsonObject
                {
                    ["schemaVersion"] = "sfx-semantic-capability-slice.v2",
                    ["capturedAtUtc"] = readA.Capture.CapturedAtUtc?.ToString("O", CultureInfo.InvariantCulture),
                    ["claim"] = "An existing SideFX capability can be read through its current database procedure, projected by CodeLightly into a faithful immutable C# semantic object, inspected without losing source identity or unknown information, and reproduced deterministically, without changing the underlying estate.",
                    ["scope"] = repeated.Count + " reads of the capability on one basis, an unknown identity and a case-changed identity, each in its own rolled-back SNAPSHOT transaction, plus offline probes of the review findings. Metadata, counts and digests only; no row payloads or credentials.",
                    ["database"] = readA.Capture.Database,
                    ["capability"] = capabilityId,
                    ["basis"] = basis,
                    ["identity"] = Identity(a.Identity),
                    ["contract"] = Contract(CapabilityProjectionContract.Id, CapabilityProjectionContract.Revision, CapabilityProjectionContract.Authority, CapabilityProjectionContract.Digest, CapabilityProjectionContract.Generator),
                    ["reader"] = new JsonObject { ["procedure"] = CapabilityProjectionContract.Procedure, ["definitionUtf16LeSha256"] = readerUtf16Before, ["definitionUtf8Sha256"] = readerUtf8 },
                    ["payloadAlgorithm"] = SemanticCanonicalJson.Algorithm,
                    ["revision"] = Revision(a.Revision),
                    ["reads"] = new JsonArray(repeated.Select((pair, index) => (JsonNode?)ReadNode("capability-" + (index + 1).ToString(CultureInfo.InvariantCulture), pair.Read, pair.Snapshot.Availability, pair.Snapshot.Refusal?.Code, pair.Snapshot.Provenance, pair.Snapshot.ProjectionDigest, pair.Snapshot.Revision)).ToArray()),
                    ["repeatedReadVariation"] = variation,
                    ["sections"] = new JsonArray(a.Sections.Select(section => (JsonNode?)new JsonObject { ["section"] = section.Name, ["disposition"] = section.Disposition.ToString(), ["unordered"] = section.Unordered, ["rows"] = section.RowCount }).ToArray()),
                    ["diagnostics"] = DiagnosticCounts(a.Diagnostics),
                    ["references"] = new JsonObject(resolutions.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => KeyValuePair.Create(pair.Key, (JsonNode?)pair.Value))),
                    ["checks"] = Checks(checks),
                    ["passed"] = passed,
                };
                WriteReceipt(receiptPath, receipt);
            }

            return passed ? 0 : 2;
        }

        // Model inspection slice

        private static async Task<int> InspectModelsAsync(string[] args)
        {
            ModelInspectionBundle bundle;
            if (Option(args, "--source") is { } sourcePath)
            {
                bundle = JsonSerializer.Deserialize<ModelInspectionBundle>(File.ReadAllText(sourcePath), SourceFileOptions) ?? throw new InvalidDataException("The saved bundle is empty.");
            }
            else if (args.Length >= 2 && args[1].StartsWith("--", StringComparison.Ordinal) == false)
            {
                bundle = await ModelInspectionReader.ReadAsync(SemanticReadClient.FromEnvironment(), args[1], Long(Option(args, "--estate")));
                if (Option(args, "--save-source") is { } savePath)
                {
                    File.WriteAllText(savePath, JsonSerializer.Serialize(bundle, SourceFileOptions), new UTF8Encoding(false));
                }
            }
            else
            {
                return Usage();
            }

            CapabilityModelInspection inspection = CapabilityModelInspection.Assemble(bundle);
            if (args.Contains("--json"))
            {
                Console.WriteLine(inspection.ToJson());
            }
            else if (Option(args, "--operation") is { } selector)
            {
                string? detail = inspection.ToOperationText(selector);
                if (detail == null)
                {
                    Console.Error.WriteLine("No model invocation '" + selector + "'. Known: " + string.Join(", ", inspection.Invocations.Select(invocation => invocation.Label + " (" + invocation.InvocationId + ")")));
                    return 1;
                }

                Console.Write(detail);
            }
            else
            {
                Console.Write(inspection.ToSummaryText());
            }

            return inspection.State == ModelInspectionState.Resolved ? 0 : 3;
        }

        private static async Task<int> VerifyModelsAsync(string capabilityId, long? estate, string? receiptPath)
        {
            SemanticReadClient client = SemanticReadClient.FromEnvironment();
            var checks = new List<Check>();
            string semanticRoot = FindSemanticRoot();
            ModelInspectionBundle bundle = await ModelInspectionReader.ReadAsync(client, capabilityId, estate);
            CapabilityModelInspection inspection = CapabilityModelInspection.Assemble(bundle);
            ImmutableArray<ModelInvocationView> invocations = inspection.Invocations;

            // 1. The three v3 model calls and two distinct providers.
            string calls = string.Join(", ", invocations.Select(invocation => invocation.Label + "@" + invocation.OperationOrdinal + " -> " + invocation.ProviderId));
            ModelInvocationView? select = invocations.FirstOrDefault(invocation => invocation.InvocationId == "select");
            ModelInvocationView? construct = invocations.FirstOrDefault(invocation => invocation.InvocationId == "construct-request");
            bool sameProviderDifferentInstructions = select != null && construct != null && select.ProviderId == construct.ProviderId
                && select.Instructions.Constructor?.Procedure != construct.Instructions.Constructor?.Procedure
                && select.Instructions.System.FirstOrDefault()?.StaticTextSha256Utf16Le != construct.Instructions.System.FirstOrDefault()?.StaticTextSha256Utf16Le;
            checks.Add(new Check("model-calls", "The inspection returns the three v3 model calls and two distinct providers; the two calls through one provider carry different instructions.",
                invocations.Length == 3 && invocations.Select(invocation => invocation.Label).SequenceEqual(new[] { "Select", "Construct request", "Summarize" })
                    && invocations.Select(invocation => invocation.OperationOrdinal).SequenceEqual(new int?[] { 2, 5, 10 })
                    && inspection.Providers.Select(provider => provider.ProviderId).SequenceEqual(new[] { "google/gemini-select", "google/gemini-summary" })
                    && invocations.All(invocation => invocation.Model.ConfiguredModel == "gemini-3.8-flash") && sameProviderDifferentInstructions,
                calls + "; configured models " + string.Join("/", invocations.Select(invocation => invocation.Model.ConfiguredModel)) + "; instruction sources "
                    + string.Join("/", invocations.Select(invocation => invocation.Instructions.Constructor?.Procedure))));

            // 2. Every model and instruction value has a traceable source.
            var untraced = new List<string>();
            foreach (ModelInvocationView invocation in invocations)
            {
                untraced.AddRange(invocation.Model.Values.Where(value => value.State != "RESOLVED" || value.TransformationDefinitionPk == null || value.TransformationDigest == null || value.JsonPath == null)
                    .Select(value => invocation.InvocationId + " model " + value.Name));
                untraced.AddRange(invocation.Instructions.System.Concat(invocation.Instructions.User)
                    .Where(segment => segment.Kind == "static" ? segment.Corroboration != "PRESENT_IN_BODY" || segment.StaticTextSha256Utf16Le == null : invocation.Instructions.Inputs.All(input => input.Name != segment.InputName || input.Source == null))
                    .Select(segment => invocation.InvocationId + " " + segment.MessageRole + " segment " + segment.Ordinal));
                untraced.AddRange(new[] { invocation.Instructions.Constructor, invocation.Instructions.Assembly }
                    .Where(procedure => procedure == null || procedure.BodyState != "CURRENT" || procedure.InstalledBodySha256 == null)
                    .Select(procedure => invocation.InvocationId + " " + (procedure?.Role ?? "procedure")));
            }

            untraced.AddRange(inspection.Providers.Where(provider => provider.Availability != SemanticAvailability.Present || provider.DefinitionDigest == null).Select(provider => "provider " + provider.ProviderId));
            int staticSegments = invocations.Sum(invocation => invocation.Instructions.System.Concat(invocation.Instructions.User).Count(segment => segment.Kind == "static"));
            int dynamicSegments = invocations.Sum(invocation => invocation.Instructions.System.Concat(invocation.Instructions.User).Count(segment => segment.Kind == "input"));
            checks.Add(new Check("traceable-values", "Every model value names its transformation definition, digest and JSON path; every static segment is corroborated in its pinned constructor body; every dynamic input names its source.",
                untraced.Count == 0,
                untraced.Count == 0
                    ? invocations.Sum(invocation => invocation.Model.Values.Length) + " model values, " + staticSegments + " static and " + dynamicSegments + " dynamic segments, "
                      + invocations.Length * 2 + " procedures CURRENT, " + inspection.Providers.Length + " providers with definition digests"
                    : "untraced: " + string.Join("; ", untraced)));

            // 3. Older templates remain inspectable but are excluded from the active instruction view.
            var activeSources = new HashSet<string>(invocations.SelectMany(invocation => new[] { invocation.Instructions.Constructor?.Procedure, invocation.Instructions.Assembly?.Procedure })
                .Concat(invocations.SelectMany(invocation => invocation.Model.Values.Select(value => value.TransformationId))).Where(id => id != null).Select(id => id!), StringComparer.Ordinal);
            checks.Add(new Check("inactive-templates", "Older templates are listed with their definitions and provider instruction rows, and none is an active instruction or model source.",
                inspection.InactiveTemplates.Length == 2 && inspection.InactiveTemplates.All(template => template.State == "SELECTED_INACTIVE" && template.ActiveReferenceState == "NOT_ACTIVE"
                    && template.DeclaredId != null && activeSources.Contains(template.DeclaredId) == false),
                string.Join("; ", inspection.InactiveTemplates.Select(template => template.DeclaredId + " " + template.State + " definition " + template.DefinitionPk + ", provider instruction rows " + string.Join("/", template.ProviderInstructionRows.Select(count => count.Rows))))
                    + "; provider instruction rows in total " + inspection.Providers.Sum(provider => provider.InstructionRows)));

            // 4. Dynamic inputs are identified; expanded prompts are reported unavailable.
            ImmutableArray<InstructionInputView> inputs = invocations.SelectMany(invocation => invocation.Instructions.Inputs).ToImmutableArray();
            checks.Add(new Check("dynamic-inputs", "Dynamic catalog, schema and result inputs are identified explicitly, and an expanded runtime prompt is reported unavailable without invocation evidence.",
                new[] { "catalog", "schema", "result" }.All(kind => inputs.Any(input => input.Kind == kind))
                    && inputs.All(input => input.ExpansionState == CapabilityModelInspection.ExpandedPromptUnavailable)
                    && invocations.All(invocation => invocation.Instructions.ExpandedPromptState == CapabilityModelInspection.ExpandedPromptUnavailable),
                string.Join("; ", invocations.Select(invocation => invocation.Label + ": " + string.Join(",", invocation.Instructions.Inputs.Select(input => input.Name + "(" + input.Kind + ")"))))
                    + "; expanded prompts " + CapabilityModelInspection.ExpandedPromptUnavailable));

            // 5. Missing, ambiguous, stale and partially resolved dependencies produce explicit states.
            var stateProbes = new List<string>();
            bool statesExplicit = true;
            void Probe(string name, ModelInspectionBundle mutated, Func<CapabilityModelInspection, bool> expected)
            {
                CapabilityModelInspection probed = CapabilityModelInspection.Assemble(mutated);
                bool ok = expected(probed);
                statesExplicit &= ok;
                ModelInvocationView? first = probed.Invocations.FirstOrDefault();
                stateProbes.Add(name + ": " + (first?.State.ToString() ?? "no invocations") + " [" + string.Join(",", (first?.Gaps ?? probed.Gaps).Select(gap => gap.Code).Distinct()) + "]" + (ok ? string.Empty : " UNEXPECTED"));
            }

            ModelInspectionBundle Mutate(string section, string field, string value, int row = 0) =>
                bundle with { ModelInvocations = bundle.ModelInvocations with { Source = bundle.ModelInvocations.Source with { DocumentText = SetField(bundle.ModelInvocations.Source.DocumentText!, section, row, field, value) } } };
            Probe("missing operation", Mutate("model_invocations", "operation_state", "MISSING"), probed => probed.Invocations[0].State == ModelInspectionState.Unresolved && probed.Invocations[0].Gaps.Any(gap => gap.Code == "OPERATION_MISSING"));
            Probe("ambiguous operation", Mutate("model_invocations", "operation_state", "AMBIGUOUS"), probed => probed.Invocations[0].State == ModelInspectionState.Unresolved && probed.Invocations[0].Gaps.Any(gap => gap.Code == "OPERATION_AMBIGUOUS"));
            Probe("stale constructor", Mutate("instruction_constructors", "body_state", "STALE", row: 1), probed => probed.Invocations[0].State == ModelInspectionState.Partial && probed.Invocations[0].Gaps.Any(gap => gap.Code == "SYSTEM_CONSTRUCTOR_BODY_STALE"));
            Probe("unresolved model path", Mutate("model_configuration", "value_state", "PATH_MISSING", row: 1), probed => probed.Invocations[0].State == ModelInspectionState.Partial && probed.Invocations[0].Gaps.Any(gap => gap.Code == "MODEL_VALUE_PATH_MISSING"));
            Probe("absent provider", bundle with { Providers = bundle.Providers.Select(read => ProviderId(read) == select?.ProviderId ? read with { Source = read.Source with { DocumentText = SetField(read.Source.DocumentText!, "provider_identity", 0, "provider_state", "ABSENT") } } : read).ToImmutableArray() },
                probed => probed.Invocations[0].State == ModelInspectionState.Partial && probed.Invocations[0].Gaps.Any(gap => gap.Code == "PROVIDER_ABSENT"));
            Probe("provider not read", bundle with { Providers = bundle.Providers.Where(read => ProviderId(read) != select?.ProviderId).ToImmutableArray() },
                probed => probed.Invocations[0].State == ModelInspectionState.Partial && probed.Invocations[0].Gaps.Any(gap => gap.Code == "PROVIDER_NOT_READ"));
            ModelInspectionBundle undeclaredBundle = await ModelInspectionReader.ReadAsync(client, "ui-page-landing", bundle.Session.Basis.EstateModelPk);
            CapabilityModelInspection undeclared = CapabilityModelInspection.Assemble(undeclaredBundle);
            bool undeclaredExplicit = undeclared.Invocations.IsEmpty && undeclared.Capability.DeclarationState == "NOT_DECLARED" && undeclared.State == ModelInspectionState.Unresolved
                && undeclared.Gaps.Any(gap => gap.Code == "DECLARATION_NOT_DECLARED");
            statesExplicit &= undeclaredExplicit;
            stateProbes.Add("live ui-page-landing (no declaration): " + undeclared.Capability.DeclarationState + ", " + undeclared.Invocations.Length + " invocations, " + undeclared.State + (undeclaredExplicit ? string.Empty : " UNEXPECTED"));
            checks.Add(new Check("explicit-states", "Missing, ambiguous, stale and partially resolved dependencies produce explicit states and gaps; an undeclared capability says so instead of inferring.",
                statesExplicit, string.Join("; ", stateProbes)));

            // 6. Saved inputs replay deterministically; a second session reproduces the inspection.
            string saved = JsonSerializer.Serialize(bundle, SourceFileOptions);
            CapabilityModelInspection replayed = CapabilityModelInspection.Assemble(JsonSerializer.Deserialize<ModelInspectionBundle>(saved, SourceFileOptions)!);
            ModelInspectionBundle second = await ModelInspectionReader.ReadAsync(client, capabilityId, bundle.Session.Basis.EstateModelPk);
            CapabilityModelInspection secondInspection = CapabilityModelInspection.Assemble(second);
            bool sameRevision = second.ModelInvocations.Capture.PinnedRevisions.SequenceEqual(bundle.ModelInvocations.Capture.PinnedRevisions)
                && secondInspection.InvocationsSnapshot.Revision.RevisionDigest == inspection.InvocationsSnapshot.Revision.RevisionDigest
                && secondInspection.CapabilitySnapshot.Revision.RevisionDigest == inspection.CapabilitySnapshot.Revision.RevisionDigest;
            checks.Add(new Check("replay-deterministic", "A saved bundle replays offline to byte-identical output and the same inspection digest; a second session at the same revision reproduces it.",
                replayed.InspectionDigest == inspection.InspectionDigest && replayed.ToJson() == inspection.ToJson() && replayed.ToSummaryText() == inspection.ToSummaryText()
                    && (sameRevision == false || secondInspection.InspectionDigest == inspection.InspectionDigest),
                "inspection digest " + inspection.InspectionDigest + "; replay " + replayed.InspectionDigest + "; second session " + secondInspection.InspectionDigest
                    + (sameRevision ? " at the same revision" : " at a DIFFERENT revision (not comparable)")));

            checks.Add(new Check("one-session-agreement", "All readings come from one SNAPSHOT session at one basis, and the capability details reading places every invocation identically.",
                bundle.ModelInvocations.Source.Basis == bundle.Capability.Source.Basis && bundle.Providers.All(read => read.Source.Basis == bundle.Capability.Source.Basis)
                    && invocations.All(invocation => invocation.CapabilityAgreement == "AGREES")
                    && inspection.Capability.SelectedDefinitionPk == inspection.CapabilitySnapshot.Capability?.SelectedDefinitionPk,
                "basis " + bundle.Session.Basis.EstateModelPk + " for " + (2 + bundle.Providers.Length) + " readings; agreement " + string.Join("/", invocations.Select(invocation => invocation.CapabilityAgreement))));

            checks.Add(new Check("estate-unchanged", "The inspection sessions generated zero estate log records and were rolled back.",
                new[] { bundle.Session, second.Session, undeclaredBundle.Session }.All(session => session.DatabaseLogRecords == 0 && session.TransactionOutcome == "ROLLED_BACK"),
                "log records " + string.Join("/", new[] { bundle.Session, second.Session, undeclaredBundle.Session }.Select(session => session.DatabaseLogRecords?.ToString(CultureInfo.InvariantCulture) ?? "unobservable"))));

            (bool bound, string boundEvidence) = GeneratedCodeBound(semanticRoot, ModelInvocationsProjectionContract.Digest);
            (bool providerBound, _) = GeneratedCodeBound(semanticRoot, ProviderProjectionContract.Digest);
            checks.Add(new Check("generated-by-codelightly", "The compiled projections are the CodeLightly output recorded in the manifest for these contracts.", bound && providerBound, boundEvidence));

            bool passed = Report(checks);
            if (receiptPath != null)
            {
                var receipt = new JsonObject
                {
                    ["schemaVersion"] = "sfx-semantic-model-inspection.v1",
                    ["capturedAtUtc"] = bundle.ModelInvocations.Capture.CapturedAtUtc?.ToString("O", CultureInfo.InvariantCulture),
                    ["claim"] = "Show me this capability's model calls, providers, models and instructions, as a supported semantic read.",
                    ["scope"] = "Read-only C# inspection and provenance. Three SNAPSHOT sessions (the capability twice and an undeclared capability), each rolled back, plus offline probes of explicit states. Instruction texts are summarized by length and digest; no row payloads or credentials.",
                    ["database"] = bundle.Session.Database,
                    ["capability"] = capabilityId,
                    ["basis"] = bundle.Session.Basis.EstateModelPk,
                    ["state"] = inspection.State.ToString(),
                    ["inspectionDigest"] = inspection.InspectionDigest,
                    ["assembler"] = CapabilityModelInspection.Assembler,
                    ["declaration"] = new JsonObject
                    {
                        ["namespace"] = inspection.InvocationsSnapshot.Summary?.DeclarationNamespace,
                        ["id"] = "model-invocations.v1",
                        ["state"] = inspection.Capability.DeclarationState,
                        ["definitionPk"] = inspection.Capability.DeclarationDefinitionPk,
                        ["digest"] = inspection.Capability.DeclarationDigest,
                        ["installedBy"] = "sfx-embody sql/migrations/declare-capability-model-invocations.commit.sql",
                    },
                    ["contracts"] = new JsonArray(
                        Contract(ModelInvocationsProjectionContract.Id, ModelInvocationsProjectionContract.Revision, ModelInvocationsProjectionContract.Authority, ModelInvocationsProjectionContract.Digest, ModelInvocationsProjectionContract.Generator),
                        Contract(CapabilityProjectionContract.Id, CapabilityProjectionContract.Revision, CapabilityProjectionContract.Authority, CapabilityProjectionContract.Digest, CapabilityProjectionContract.Generator),
                        Contract(ProviderProjectionContract.Id, ProviderProjectionContract.Revision, ProviderProjectionContract.Authority, ProviderProjectionContract.Digest, ProviderProjectionContract.Generator)),
                    ["readings"] = new JsonArray(ReadingNodes(inspection, bundle)),
                    ["invocations"] = new JsonArray(invocations.Select(invocation => (JsonNode?)new JsonObject
                    {
                        ["label"] = invocation.Label,
                        ["operationId"] = invocation.OperationId,
                        ["ordinal"] = invocation.OperationOrdinal,
                        ["providerId"] = invocation.ProviderId,
                        ["bindingId"] = invocation.ProviderAuthority.BindingId,
                        ["configuredModel"] = invocation.Model.ConfiguredModel,
                        ["endpointTemplate"] = invocation.Model.EndpointTemplate,
                        ["modelSource"] = invocation.Model.Values.FirstOrDefault(value => value.Name == "configuredModel") is { } model
                            ? model.TransformationNamespace + "/" + model.TransformationId + " definition " + model.TransformationDefinitionPk + " digest " + model.TransformationDigest + " at " + model.JsonPath : null,
                        ["instructionSource"] = invocation.Instructions.Constructor?.Procedure,
                        ["constructorBodySha256Utf16Le"] = invocation.Instructions.Constructor?.InstalledBodySha256,
                        ["assembly"] = invocation.Instructions.Assembly?.Procedure,
                        ["systemSegments"] = new JsonArray(invocation.Instructions.System.Select(segment => (JsonNode?)(segment.Kind == "static"
                            ? "static " + segment.StaticText?.Length + " chars sha256-utf16le " + segment.StaticTextSha256Utf16Le + " " + segment.Corroboration
                            : "{" + segment.InputName + "}")).ToArray()),
                        ["userSegments"] = new JsonArray(invocation.Instructions.User.Select(segment => (JsonNode?)(segment.Kind == "static" ? "static " + segment.StaticText?.Length + " chars sha256-utf16le " + segment.StaticTextSha256Utf16Le + " " + segment.Corroboration : "{" + segment.InputName + "}")).ToArray()),
                        ["dynamicInputs"] = new JsonArray(invocation.Instructions.Inputs.Select(input => (JsonNode?)(input.Name + " (" + input.Kind + ", " + input.MessageRole + ")")).ToArray()),
                        ["expandedPrompt"] = invocation.Instructions.ExpandedPromptState,
                        ["state"] = invocation.State.ToString(),
                        ["gaps"] = invocation.Gaps.Length,
                    }).ToArray()),
                    ["providers"] = new JsonArray(inspection.Providers.Select(provider => (JsonNode?)new JsonObject
                    {
                        ["providerId"] = provider.ProviderId,
                        ["availability"] = provider.Availability.ToString(),
                        ["role"] = provider.CapabilityRole ?? provider.ProviderRole,
                        ["definitionDigest"] = provider.DefinitionDigest,
                        ["engagements"] = provider.Engagements.Length,
                        ["instructionRows"] = provider.InstructionRows,
                        ["projectionDigest"] = provider.ProjectionDigest,
                    }).ToArray()),
                    ["inactiveTemplates"] = new JsonArray(inspection.InactiveTemplates.Select(template => (JsonNode?)new JsonObject
                    {
                        ["declaredId"] = template.DeclaredId,
                        ["state"] = template.State,
                        ["definitionPk"] = template.DefinitionPk,
                        ["digest"] = template.Digest,
                        ["providerInstructionRows"] = new JsonArray(template.ProviderInstructionRows.Select(count => (JsonNode?)(count.ProviderId + " " + count.Rows)).ToArray()),
                    }).ToArray()),
                    ["gaps"] = new JsonArray(inspection.Gaps.Select(gap => (JsonNode?)(gap.Severity + " " + gap.Code + " " + gap.Subject)).ToArray()),
                    ["checks"] = Checks(checks),
                    ["passed"] = passed,
                };
                WriteReceipt(receiptPath, receipt);
            }

            return passed ? 0 : 2;
        }

        private static JsonNode?[] ReadingNodes(CapabilityModelInspection inspection, ModelInspectionBundle bundle)
        {
            var nodes = new List<JsonNode?>
            {
                ReadNode("model-invocations", bundle.ModelInvocations, inspection.InvocationsSnapshot.Availability, inspection.InvocationsSnapshot.Refusal?.Code, inspection.InvocationsSnapshot.Provenance, inspection.InvocationsSnapshot.ProjectionDigest, inspection.InvocationsSnapshot.Revision),
                ReadNode("capability-details", bundle.Capability, inspection.CapabilitySnapshot.Availability, inspection.CapabilitySnapshot.Refusal?.Code, inspection.CapabilitySnapshot.Provenance, inspection.CapabilitySnapshot.ProjectionDigest, inspection.CapabilitySnapshot.Revision),
            };
            for (int index = 0; index < bundle.Providers.Length; index++)
            {
                ProviderSnapshot snapshot = inspection.ProviderSnapshots.Single(candidate => candidate.Provenance.Arguments.First(argument => argument.Role == "identity").Value == ProviderId(bundle.Providers[index]));
                nodes.Add(ReadNode("provider:" + ProviderId(bundle.Providers[index]), bundle.Providers[index], snapshot.Availability, snapshot.Refusal?.Code, snapshot.Provenance, snapshot.ProjectionDigest, snapshot.Revision));
            }

            return nodes.ToArray();
        }

        private static string? ProviderId(SemanticRead read) => read.Source.Arguments.FirstOrDefault(argument => argument.Role == "identity")?.Value;

        // Sets one field of one row of one section in a document (offline probes only).
        private static string SetField(string document, string section, int row, string field, string value)
        {
            JsonNode node = JsonNode.Parse(document)!;
            node[section]![row]![field] = value;
            return node.ToJsonString();
        }

        // Shared evidence

        private static (bool Stable, string Evidence, JsonObject Variation) RepeatedReadEvidence(List<(SemanticRead Read, CapabilitySnapshot Snapshot)> reads, ImmutableArray<string> unordered)
        {
            var orderVaried = new SortedSet<string>(StringComparer.Ordinal);
            var contentVaried = new SortedSet<string>(StringComparer.Ordinal);
            var orderedHashes = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            var multisetHashes = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            foreach ((SemanticRead read, _) in reads)
            {
                if (read.Source.DocumentText == null)
                {
                    continue;
                }

                using JsonDocument document = JsonDocument.Parse(read.Source.DocumentText);
                foreach (JsonProperty section in document.RootElement.EnumerateObject())
                {
                    string ordered = Sha(section.Value.GetRawText());
                    string multiset = section.Value.ValueKind == JsonValueKind.Array
                        ? Sha(string.Join("\n", section.Value.EnumerateArray().Select(row => Sha(row.GetRawText())).OrderBy(hash => hash, StringComparer.Ordinal)))
                        : ordered;
                    (orderedHashes.TryGetValue(section.Name, out HashSet<string>? o) ? o : orderedHashes[section.Name] = new HashSet<string>()).Add(ordered);
                    (multisetHashes.TryGetValue(section.Name, out HashSet<string>? m) ? m : multisetHashes[section.Name] = new HashSet<string>()).Add(multiset);
                }
            }

            foreach ((string section, HashSet<string> hashes) in orderedHashes)
            {
                if (multisetHashes[section].Count > 1)
                {
                    contentVaried.Add(section);
                }
                else if (hashes.Count > 1)
                {
                    orderVaried.Add(section);
                }
            }

            var byRevision = reads.GroupBy(pair => pair.Snapshot.Revision.RevisionDigest).ToList();
            bool sameRevisionSameProjection = byRevision.All(group => group.Select(pair => pair.Snapshot.ProjectionDigest).Distinct().Count() == 1);
            List<string> undeclaredOrder = orderVaried.Where(section => unordered.Contains(section) == false).ToList();
            bool contentStableWithinRevision = byRevision.Count > 1 || contentVaried.Count == 0;
            bool stable = sameRevisionSameProjection && undeclaredOrder.Count == 0 && contentStableWithinRevision;
            string evidence = reads.Count + " reads, " + byRevision.Count + " revision(s), " + reads.Select(pair => pair.Snapshot.ProjectionDigest).Distinct().Count() + " projection digest(s), "
                + reads.Select(pair => pair.Read.Source.DocumentText == null ? null : Sha(pair.Read.Source.DocumentText)).Distinct().Count() + " distinct document(s); row order varied in "
                + (orderVaried.Count == 0 ? "no section" : string.Join(",", orderVaried)) + (undeclaredOrder.Count > 0 ? " (UNDECLARED: " + string.Join(",", undeclaredOrder) + ")" : string.Empty)
                + (contentVaried.Count > 0 ? "; content varied in " + string.Join(",", contentVaried) : string.Empty);
            var variation = new JsonObject
            {
                ["reads"] = reads.Count,
                ["revisions"] = byRevision.Count,
                ["projectionDigests"] = new JsonArray(reads.Select(pair => (JsonNode?)pair.Snapshot.ProjectionDigest).Distinct().ToArray()),
                ["documentDigests"] = reads.Select(pair => pair.Read.Source.DocumentText == null ? null : Sha(pair.Read.Source.DocumentText)).Distinct().Count(),
                ["orderVariedSections"] = new JsonArray(orderVaried.Select(section => (JsonNode?)section).ToArray()),
                ["contentVariedSections"] = new JsonArray(contentVaried.Select(section => (JsonNode?)section).ToArray()),
                ["declaredUnorderedSections"] = unordered.Length,
            };
            return (stable, evidence, variation);
        }

        private static Check FindingCheck(string id, string claim, Func<(bool Passed, string Evidence)> probe)
        {
            (bool passed, string evidence) = probe();
            return new Check(id, claim, passed, evidence);
        }

        private static bool Report(List<Check> checks)
        {
            bool passed = checks.All(check => check.Passed);
            foreach (Check check in checks)
            {
                Console.WriteLine((check.Passed ? "PASS " : "FAIL ") + check.Id + ": " + check.Evidence);
            }

            Console.WriteLine(passed ? "All " + checks.Count + " checks passed." : checks.Count(check => check.Passed == false) + " check(s) failed.");
            return passed;
        }

        private static string Argument(SemanticProvenance provenance, string parameter)
        {
            SemanticBoundArgument? argument = provenance.Arguments.FirstOrDefault(candidate => candidate.Parameter == parameter);
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
        // from System.Exception), the read client and session.
        private static IEnumerable<Type> SemanticObjectTypes() => typeof(CapabilitySnapshot).Assembly.GetExportedTypes()
            .Where(type => type.Namespace == "SFX.Semantics" && type.IsClass && type.IsAbstract == false
                && typeof(Exception).IsAssignableFrom(type) == false && type != typeof(SemanticReadClient) && type != typeof(SemanticReadSession));

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

        private static (bool Bound, string Evidence) GeneratedCodeBound(string semanticRoot, string contractDigest)
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

            bool listed = manifest["contracts"]!.AsArray().Any(contract => (string?)contract!["digest"] == contractDigest);
            string generator = (string)manifest["generator"]!["emitter"]! + " " + (string?)manifest["generator"]!["sourceDigest"];
            return (mismatches.Count == 0 && listed, artifacts + " artifact hash(es) " + (mismatches.Count == 0 ? "match" : "differ: " + string.Join(", ", mismatches))
                + "; contract digest " + contractDigest + (listed ? " in manifest" : " NOT in manifest") + "; generator " + generator);
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

        private static string Sha(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();

        private static JsonObject? Identity(SemanticIdentity? identity) => identity == null ? null : new JsonObject
        {
            ["namespace"] = identity.Namespace,
            ["kind"] = identity.Kind,
            ["declaredId"] = identity.DeclaredId,
            ["revisionLocator"] = identity.Revision,
        };

        private static JsonObject Contract(string id, string revision, string authority, string digest, string generator) => new JsonObject
        {
            ["id"] = id,
            ["revision"] = revision,
            ["authority"] = authority,
            ["digest"] = digest,
            ["generator"] = generator,
        };

        private static JsonObject Revision(SemanticRevision revision) => new JsonObject
        {
            ["revisionDigest"] = revision.RevisionDigest,
            ["basis"] = revision.Basis,
            ["readerDefinitionDigest"] = revision.ReaderDefinitionDigest,
            ["dependencies"] = revision.Dependencies.Length,
            ["unpinned"] = revision.Unpinned,
            ["pinnedByReadSession"] = new JsonArray(revision.Dependencies.Where(dependency => dependency.Source == "read-session").Select(dependency => (JsonNode?)(dependency.Kind + " " + dependency.Id + " " + dependency.Locator + " " + dependency.Digest)).ToArray()),
        };

        private static JsonObject ReadNode(string label, SemanticRead read, SemanticAvailability availability, string? refusal, SemanticProvenance provenance, string? projectionDigest, SemanticRevision revision) => new JsonObject
        {
            ["label"] = label,
            ["procedure"] = provenance.Procedure,
            ["identity"] = read.Source.Identity,
            ["basis"] = read.Source.Basis,
            ["availability"] = availability.ToString(),
            ["refusal"] = refusal,
            ["rowResultSets"] = read.Source.RowResultSets,
            ["documentSha256"] = provenance.DocumentSha256,
            ["documentUtf8Bytes"] = provenance.DocumentUtf8Bytes,
            ["projectionDigest"] = projectionDigest,
            ["revisionDigest"] = revision.RevisionDigest,
            ["readerDefinitionDigest"] = read.Capture.ReaderDefinitionDigest,
            ["databaseLogRecords"] = read.Capture.DatabaseLogRecords,
            ["elapsedMilliseconds"] = read.Capture.ElapsedMilliseconds,
        };

        private static JsonObject DiagnosticCounts(ImmutableArray<SemanticDiagnostic> diagnostics) =>
            new JsonObject(diagnostics.GroupBy(diagnostic => diagnostic.Severity + " " + diagnostic.Code).OrderBy(group => group.Key, StringComparer.Ordinal)
                .Select(group => KeyValuePair.Create(group.Key, (JsonNode?)group.Count())));

        private static JsonArray Checks(List<Check> checks) => new JsonArray(checks.Select(check => (JsonNode?)new JsonObject
        {
            ["id"] = check.Id,
            ["claim"] = check.Claim,
            ["passed"] = check.Passed,
            ["evidence"] = check.Evidence,
        }).ToArray());

        private static void WriteReceipt(string path, JsonObject receipt)
        {
            string json = receipt.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }).Replace("\r\n", "\n") + "\n";
            File.WriteAllText(path, json, new UTF8Encoding(false));
            Console.WriteLine("Receipt saved: " + Path.GetFullPath(path));
        }

        private sealed record Check(string Id, string Claim, bool Passed, string Evidence);
    }
}
