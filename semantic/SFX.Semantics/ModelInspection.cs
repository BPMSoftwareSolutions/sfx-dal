#nullable enable

using System.Buffers;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace SFX.Semantics
{
    /// <summary>
    /// Everything one model inspection read, captured in one SNAPSHOT session: the estate's declared
    /// model invocations, the capability details and every provider the invocations name. Saved
    /// bundles replay offline to the same inspection.
    /// </summary>
    public sealed record ModelInspectionBundle(string CapabilityId, SemanticRead ModelInvocations, SemanticRead Capability, ImmutableArray<SemanticRead> Providers, SemanticSessionOutcome Session)
    {
        /// <summary>The bundle format.</summary>
        public const string CurrentVersion = "sfx-model-inspection-bundle.v1";

        /// <summary>The bundle format this instance was written with.</summary>
        public string Version { get; init; } = CurrentVersion;
    }

    /// <summary>Whether everything an invocation's inspection depends on resolved.</summary>
    public enum ModelInspectionState
    {
        /// <summary>Every relationship resolved, every digest is current and every source agrees.</summary>
        Resolved,

        /// <summary>The invocation is identified, but some dependency is missing, stale, ambiguous or unavailable.</summary>
        Partial,

        /// <summary>The invocation's execution operation itself did not resolve.</summary>
        Unresolved,
    }

    /// <summary>A dependency that did not resolve cleanly, with the reading that reported it.</summary>
    public sealed record ModelInspectionGap(string Code, string Severity, string Subject, string Detail, string Source);

    /// <summary>The capability, its selected definition and execution authority, and the read basis.</summary>
    public sealed record ModelCapabilityView(
        string CapabilityId,
        SemanticIdentity? Identity,
        long? SelectedVersionPk,
        long? SelectedDefinitionPk,
        string? DefinitionDigest,
        long? ExecutionAuthorityVersionPk,
        string? ExecutionAuthorityDigest,
        int? ExecutionAuthorityVersions,
        long Basis,
        string BasisScope,
        SemanticAvailability CapabilityAvailability,
        SemanticAvailability InvocationsAvailability,
        string DeclarationState,
        long? DeclarationDefinitionPk,
        string? DeclarationDigest);

    /// <summary>The model port an invocation runs on.</summary>
    public sealed record ModelPortView(string? PortId, long? PortVersionPk, string? Digest, string? PlatformCapabilityId);

    /// <summary>The provider authority the model port declares. Credential values are never read; only the reference name is shown.</summary>
    public sealed record ModelProviderAuthorityView(int? Authorities, string? BindingId, string? ProviderAuthorityId, string? ProviderKind, string? EndpointAuthorityDigest, string? CredentialReference);

    /// <summary>One configuration value with the definition and JSON path that supply it.</summary>
    public sealed record ModelConfigurationEntry(string Name, string? Value, string State, string? JsonPath, string? TransformationNamespace, string? TransformationId, long? TransformationDefinitionPk, string? TransformationDigest);

    /// <summary>The configured model of an invocation.</summary>
    public sealed record ModelConfigurationView(string? ConfiguredModel, string? EndpointTemplate, string? EndpointModel, string? AdapterIdentity, ImmutableArray<ModelConfigurationEntry> Values);

    /// <summary>A procedure that constructs an instruction or assembles messages, with declared and installed digests.</summary>
    public sealed record InstructionProcedureView(string Role, string? Procedure, string? DeclaredBodySha256, string? InstalledBodySha256, string BodyState,
        string? PortNamespace, string? PortId, string? PortDigest, string PortState, string? PortStatement, string StatementCorroboration);

    /// <summary>One ordered message segment: declared static text or a dynamic input placeholder.</summary>
    public sealed record InstructionSegmentView(string MessageRole, int Ordinal, string? Kind, string? StaticText, string? StaticTextSha256Utf16Le, string? InputName, string Corroboration);

    /// <summary>A dynamic input. Its value is never expanded without evidence from a specific invocation.</summary>
    public sealed record InstructionInputView(string Name, string? Kind, string? MessageRole, string? Source, string? Description, int SegmentReferences, string ExpansionState);

    /// <summary>The declared response schema and request policy.</summary>
    public sealed record ResponsePolicyView(string? Format, string? Schema, string? SchemaSha256Utf16Le, string SchemaCorroboration, int? MaximumOutputTokens, string? Temperature,
        int? TimeoutMilliseconds, int? MaximumAuthorizedAttempts, bool? ProviderSubstitutionAllowed);

    /// <summary>The active instructions of one invocation: who constructs them, their segments, inputs and response policy.</summary>
    public sealed record InstructionView(string? ConstructorOperationId, string? ConstructorScenarioId, InstructionProcedureView? Constructor, InstructionProcedureView? Assembly,
        ImmutableArray<InstructionSegmentView> System, ImmutableArray<InstructionSegmentView> User, ImmutableArray<InstructionInputView> Inputs, ResponsePolicyView? Response,
        string ExpandedPromptState);

    /// <summary>
    /// One model invocation, the central object: its operation and position, port, provider relationship,
    /// configured model and the instructions constructed for this step. Two invocations through the same
    /// provider can carry different instructions, so instructions live here and not on the provider.
    /// </summary>
    public sealed record ModelInvocationView(
        int Ordinal,
        string? InvocationId,
        string? Label,
        string? OperationId,
        int? OperationOrdinal,
        long? ExecutionOperationPk,
        string OperationState,
        string? RequestId,
        ModelPortView Port,
        string? ProviderId,
        string ProviderState,
        ModelProviderAuthorityView ProviderAuthority,
        string CapabilityAgreement,
        string? CompositionOperationId,
        int? CompositionOrdinal,
        string CompositionLinkState,
        int? ConstructorOrdinal,
        string ConstructorLinkState,
        string SequenceState,
        ModelConfigurationView Model,
        InstructionView Instructions,
        ModelInspectionState State,
        ImmutableArray<ModelInspectionGap> Gaps);

    /// <summary>One engagement of a provider by the inspected capability.</summary>
    public sealed record ModelProviderEngagementView(string? EngagementKind, string? PortId, long? PortVersionPk, string? BindingId, string? ProviderAuthorityId, string? ProviderKind,
        string? EndpointAuthorityDigest, string? EndpointTemplate, string? CredentialReference, string? CredentialValueState);

    /// <summary>A group of instruction-bearing rows the provider reader returns for one owning definition.</summary>
    public sealed record ProviderInstructionOwnerView(string? OwnerKind, string? OwnerId, string? NamespaceId, int Rows, string Disposition);

    /// <summary>A provider: exact identity, role, selected definition, the capability's engagements, and its instruction-bearing material (not execution-path authority).</summary>
    public sealed record ModelProviderView(string ProviderId, SemanticAvailability Availability, string? ProviderState, string? NamespaceId, string? DeclaredName, string? ProviderRole,
        string? CapabilityRole, string? DefinitionDigest, ImmutableArray<ModelProviderEngagementView> Engagements, int InstructionRows, ImmutableArray<ProviderInstructionOwnerView> InstructionOwners,
        string? ProjectionDigest, string RevisionDigest);

    /// <summary>An earlier template: inspectable, excluded from every active instruction view.</summary>
    public sealed record InactiveTemplateView(string? NamespaceId, string? Kind, string? DeclaredId, string? Reason, long? DefinitionPk, string? Digest, string State, string ActiveReferenceState,
        ImmutableArray<ProviderInstructionCount> ProviderInstructionRows);

    /// <summary>How many instruction-bearing rows one provider reading returns for a definition.</summary>
    public sealed record ProviderInstructionCount(string ProviderId, int Rows);

    /// <summary>
    /// "Show me this capability's model calls, providers, models and instructions" as one immutable,
    /// provenance-carrying object. Assembled only from projected snapshots, so a saved bundle replays
    /// to byte-identical output and the same inspection digest.
    /// </summary>
    public sealed class CapabilityModelInspection
    {
        /// <summary>Identifies the assembly rules recorded in the digest.</summary>
        public const string Assembler = "sfx-model-inspection.v1";

        /// <summary>The expansion state of every runtime prompt in this read-only slice.</summary>
        public const string ExpandedPromptUnavailable = "UNAVAILABLE_WITHOUT_INVOCATION_EVIDENCE";

        private CapabilityModelInspection(ModelInspectionBundle bundle, ModelInvocationsSnapshot invocations, CapabilitySnapshot capability, ImmutableArray<ProviderSnapshot> providers)
        {
            Bundle = bundle;
            InvocationsSnapshot = invocations;
            CapabilitySnapshot = capability;
            ProviderSnapshots = providers;
        }

        /// <summary>The saved inputs this inspection was assembled from.</summary>
        public ModelInspectionBundle Bundle { get; }

        /// <summary>The estate's model-invocation reading.</summary>
        public ModelInvocationsSnapshot InvocationsSnapshot { get; }

        /// <summary>The capability details reading of the same session.</summary>
        public CapabilitySnapshot CapabilitySnapshot { get; }

        /// <summary>Every provider reading of the same session.</summary>
        public ImmutableArray<ProviderSnapshot> ProviderSnapshots { get; }

        /// <summary>Capability identity, selected definition, execution authority and read basis.</summary>
        public ModelCapabilityView Capability { get; private set; } = null!;

        /// <summary>The model invocations, in declared order.</summary>
        public ImmutableArray<ModelInvocationView> Invocations { get; private set; }

        /// <summary>The distinct providers the invocations use.</summary>
        public ImmutableArray<ModelProviderView> Providers { get; private set; }

        /// <summary>Templates the declaration marks inactive.</summary>
        public ImmutableArray<InactiveTemplateView> InactiveTemplates { get; private set; }

        /// <summary>Every gap across the inspection.</summary>
        public ImmutableArray<ModelInspectionGap> Gaps { get; private set; }

        /// <summary>Resolved only when every invocation resolved and no reading reported an error.</summary>
        public ModelInspectionState State { get; private set; }

        /// <summary>sha256 over the stable inspection view (capture time and duration excluded).</summary>
        public string InspectionDigest { get; private set; } = string.Empty;

        /// <summary>Assembles an inspection from a bundle. Pure: the same bundle always gives the same inspection.</summary>
        public static CapabilityModelInspection Assemble(ModelInspectionBundle bundle)
        {
            ArgumentNullException.ThrowIfNull(bundle);
            ModelInvocationsSnapshot invocations = ModelInvocationsSnapshot.Project(bundle.ModelInvocations.Source, bundle.ModelInvocations.Capture);
            CapabilitySnapshot capability = CapabilitySnapshot.Project(bundle.Capability.Source, bundle.Capability.Capture);
            ImmutableArray<ProviderSnapshot> providers = bundle.Providers.Select(read => ProviderSnapshot.Project(read.Source, read.Capture))
                .OrderBy(provider => provider.Provenance.Arguments.FirstOrDefault(argument => argument.Role == "identity")?.Value, StringComparer.Ordinal)
                .ToImmutableArray();
            var inspection = new CapabilityModelInspection(bundle, invocations, capability, providers);
            inspection.Build();
            return inspection;
        }

        /// <summary>Distinct provider ids named by a model-invocation reading, in ordinal order.</summary>
        public static ImmutableArray<string> ProvidersOf(ModelInvocationsSnapshot invocations) =>
            invocations.Invocations.Select(invocation => invocation.ProviderId).Where(id => id != null).Select(id => id!).Distinct(StringComparer.Ordinal).OrderBy(id => id, StringComparer.Ordinal).ToImmutableArray();

        private void Build()
        {
            var gaps = new List<ModelInspectionGap>();
            ModelInvocationSummary? summary = InvocationsSnapshot.Summary;
            Capability = new ModelCapabilityView(
                Bundle.CapabilityId,
                CapabilitySnapshot.Identity,
                summary?.SelectedVersionPk,
                summary?.SelectedDefinitionPk,
                summary?.CapabilityDefinitionDigest,
                summary?.ExecutionAuthorityVersionPk,
                summary?.ExecutionAuthorityDigest,
                summary?.ExecutionAuthorityVersions,
                Bundle.Session.Basis.EstateModelPk,
                "estate " + Bundle.Session.Basis.EstateModelPk.ToString(CultureInfo.InvariantCulture) + " is a mutable pointer; the readings' revision digests identify what was read",
                CapabilitySnapshot.Availability,
                InvocationsSnapshot.Availability,
                summary?.DeclarationState ?? "UNAVAILABLE",
                summary?.DeclarationDefinitionPk,
                summary?.DeclarationDigest);

            AddReadingGaps(gaps, "model-invocations", InvocationsSnapshot.Availability, InvocationsSnapshot.Diagnostics, InvocationsSnapshot.Revision);
            AddReadingGaps(gaps, "capability-details", CapabilitySnapshot.Availability, CapabilitySnapshot.Diagnostics, CapabilitySnapshot.Revision);
            if (summary != null && summary.DeclarationState != "DECLARED")
            {
                gaps.Add(new ModelInspectionGap("DECLARATION_" + summary.DeclarationState, "REFUSE", summary.DeclarationNamespace, "No usable model-invocation declaration; nothing is inferred in its place.", "model-invocations"));
            }

            if (summary != null && CapabilitySnapshot.Capability is { } capabilityRoot && capabilityRoot.SelectedDefinitionPk != summary.SelectedDefinitionPk)
            {
                gaps.Add(new ModelInspectionGap("CAPABILITY_DEFINITION_DISAGREES", "REFUSE", Bundle.CapabilityId,
                    "The two readings of one session select different capability definitions.", "cross-reading"));
            }

            foreach (ModelInvocationFinding finding in InvocationsSnapshot.Findings)
            {
                gaps.Add(new ModelInspectionGap(finding.Code, finding.Severity, finding.Subject ?? string.Empty, finding.Detail ?? string.Empty, "model-invocations"));
            }

            Providers = ProviderSnapshots.Select(BuildProvider).ToImmutableArray();
            foreach (ModelProviderView provider in Providers)
            {
                ProviderSnapshot snapshot = ProviderSnapshots.Single(candidate => ProviderIdOf(candidate) == provider.ProviderId);
                AddReadingGaps(gaps, "provider-details:" + provider.ProviderId, snapshot.Availability, snapshot.Diagnostics, snapshot.Revision);
            }

            InactiveTemplates = InvocationsSnapshot.InactiveTemplates.Select(template => new InactiveTemplateView(
                template.NamespaceId, template.ObjectKind, template.DeclaredId, template.Reason, template.SemanticObjectDefinitionPk, template.DefinitionDigest,
                template.TemplateState, template.ActiveReferenceState,
                Providers.Select(provider => new ProviderInstructionCount(provider.ProviderId,
                    provider.InstructionOwners.Where(owner => owner.OwnerId == template.DeclaredId && owner.NamespaceId == template.NamespaceId).Sum(owner => owner.Rows))).ToImmutableArray()))
                .ToImmutableArray();

            Invocations = InvocationsSnapshot.Invocations.OrderBy(invocation => invocation.InvocationOrdinal).Select(BuildInvocation).ToImmutableArray();
            foreach (ModelInvocationView invocation in Invocations)
            {
                gaps.AddRange(invocation.Gaps.Where(gap => gaps.Contains(gap) == false));
            }

            Gaps = gaps.Distinct().ToImmutableArray();
            bool readingsClean = InvocationsSnapshot.Availability == SemanticAvailability.Present && CapabilitySnapshot.Availability == SemanticAvailability.Present
                && Providers.All(provider => provider.Availability == SemanticAvailability.Present) && Capability.DeclarationState == "DECLARED";
            State = Invocations.Length > 0 && readingsClean && Invocations.All(invocation => invocation.State == ModelInspectionState.Resolved) && Gaps.All(gap => gap.Severity == "INFO")
                ? ModelInspectionState.Resolved
                : Invocations.Any(invocation => invocation.State != ModelInspectionState.Unresolved) ? ModelInspectionState.Partial : ModelInspectionState.Unresolved;
            InspectionDigest = "sha256:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ToJson(includeCapture: false)))).ToLowerInvariant();
        }

        private ModelInvocationView BuildInvocation(ModelInvocation invocation)
        {
            var gaps = new List<ModelInspectionGap>();
            string subject = invocation.Label ?? invocation.InvocationId ?? invocation.InvocationOrdinal.ToString(CultureInfo.InvariantCulture);
            void Gap(string code, string severity, string detail, string source = "model-invocations") => gaps.Add(new ModelInspectionGap(code, severity, subject, detail, source));

            if (invocation.OperationState != "RESOLVED")
            {
                Gap("OPERATION_" + invocation.OperationState, "REFUSE", "The declared execution operation " + invocation.OperationId + " is " + invocation.OperationState + " in the selected execution authority.");
            }

            if (invocation.ProviderState != "DECLARED_ON_PORT")
            {
                Gap("PROVIDER_" + invocation.ProviderState, "REFUSE", "The model port declares no provider for this invocation.");
            }

            if (invocation.ProviderAuthorities != 1)
            {
                Gap("PROVIDER_AUTHORITY_NOT_UNIQUE", "WARN", (invocation.ProviderAuthorities ?? 0).ToString(CultureInfo.InvariantCulture) + " provider authorities are declared on the model port.");
            }

            foreach ((string linkState, string code, string what) in new[]
            {
                (invocation.ConstructorLinkState, "CONSTRUCTOR_", "instruction constructor operation"),
                (invocation.CompositionLinkState, "COMPOSITION_", "request composition operation"),
            })
            {
                if (linkState != "CONSISTENT")
                {
                    Gap(code + linkState, "REFUSE", "The " + what + " is " + linkState + ".");
                }
            }

            if (invocation.SequenceState != "ORDERED")
            {
                Gap("SEQUENCE_" + invocation.SequenceState, "WARN", "Constructor, composition and invocation are not in execution order.");
            }

            string agreement = CapabilityAgreement(invocation);
            if (agreement != "AGREES")
            {
                Gap("CAPABILITY_READING_" + agreement.Split(':')[0], agreement.StartsWith("DISAGREES", StringComparison.Ordinal) ? "REFUSE" : "WARN",
                    "The capability details reading of the same session " + agreement.ToLowerInvariant().Replace('_', ' ') + ".", "cross-reading");
            }

            ImmutableArray<ModelConfigurationEntry> values = InvocationsSnapshot.ConfigurationValues.Where(value => value.InvocationOrdinal == invocation.InvocationOrdinal)
                .OrderBy(value => value.ValueName, StringComparer.Ordinal)
                .Select(value => new ModelConfigurationEntry(value.ValueName, value.Value, value.ValueState, value.JsonPath, value.TransformationNamespace, value.TransformationId,
                    value.TransformationDefinitionPk, value.TransformationDigest))
                .ToImmutableArray();
            foreach (ModelConfigurationEntry value in values.Where(value => value.State != "RESOLVED"))
            {
                Gap("MODEL_VALUE_" + value.State, "REFUSE", value.Name + " at " + value.JsonPath + " is " + value.State + ".");
            }

            if (values.All(value => value.Name != "configuredModel"))
            {
                Gap("MODEL_VALUE_NOT_DECLARED", "REFUSE", "The declaration names no configuredModel path.");
            }

            string? Value(string name) => values.FirstOrDefault(value => value.Name == name && value.State == "RESOLVED")?.Value;
            var model = new ModelConfigurationView(Value("configuredModel"), Value("endpointTemplate"), Value("endpointModel"), Value("adapterIdentity"), values);

            InstructionProcedureView? Procedure(string role)
            {
                InstructionConstructor? row = InvocationsSnapshot.Constructors.FirstOrDefault(candidate => candidate.InvocationOrdinal == invocation.InvocationOrdinal && candidate.Role == role);
                return row == null ? null : new InstructionProcedureView(row.Role, row.ProcedureName, row.DeclaredBodySha256, row.InstalledBodySha256, row.BodyState,
                    row.ConstructorPortNamespace, row.ConstructorPortId, row.PortDigest, row.PortState, row.PortStatement, row.StatementCorroboration);
            }

            InstructionProcedureView? constructor = Procedure("SYSTEM_CONSTRUCTOR");
            InstructionProcedureView? assembly = Procedure("MESSAGE_ASSEMBLY");
            foreach (InstructionProcedureView? procedure in new[] { constructor, assembly })
            {
                if (procedure == null)
                {
                    Gap("INSTRUCTION_PROCEDURE_NOT_DECLARED", "REFUSE", "No instruction procedure row for this invocation.");
                    continue;
                }

                if (procedure.BodyState != "CURRENT")
                {
                    Gap(procedure.Role + "_BODY_" + procedure.BodyState, procedure.BodyState == "STALE" ? "WARN" : "REFUSE",
                        procedure.Procedure + " installed body " + (procedure.InstalledBodySha256 ?? "absent") + " differs from the declared " + (procedure.DeclaredBodySha256 ?? "none") + ".");
                }

                if (procedure.PortState is not ("SELECTED" or "NOT_APPLICABLE"))
                {
                    Gap("CONSTRUCTOR_PORT_" + procedure.PortState, "REFUSE", "The constructor port " + procedure.PortId + " is " + procedure.PortState + ".");
                }
            }

            ImmutableArray<InstructionSegmentView> Segments(string role) => InvocationsSnapshot.Segments
                .Where(segment => segment.InvocationOrdinal == invocation.InvocationOrdinal && segment.MessageRole == role)
                .OrderBy(segment => segment.SegmentOrdinal)
                .Select(segment => new InstructionSegmentView(segment.MessageRole, segment.SegmentOrdinal, segment.SegmentKind, segment.StaticText, segment.StaticTextSha256Utf16le, segment.InputName, segment.Corroboration))
                .ToImmutableArray();
            ImmutableArray<InstructionSegmentView> system = Segments("system");
            ImmutableArray<InstructionSegmentView> user = Segments("user");
            foreach (InstructionSegmentView segment in system.Concat(user).Where(segment => segment.Corroboration is not ("PRESENT_IN_BODY" or "NOT_APPLICABLE")))
            {
                Gap("STATIC_TEXT_" + segment.Corroboration, "WARN", segment.MessageRole + " segment " + segment.Ordinal.ToString(CultureInfo.InvariantCulture) + " is " + segment.Corroboration + ".");
            }

            if (system.IsEmpty)
            {
                Gap("SYSTEM_INSTRUCTION_NOT_DECLARED", "REFUSE", "The declaration has no system message segments for this invocation.");
            }

            ImmutableArray<InstructionInputView> inputs = InvocationsSnapshot.Inputs.Where(input => input.InvocationOrdinal == invocation.InvocationOrdinal)
                .OrderBy(input => input.InputName, StringComparer.Ordinal)
                .Select(input => new InstructionInputView(input.InputName, input.InputKind, input.MessageRole, input.Source, input.Description, input.SegmentReferences, input.ExpansionState))
                .ToImmutableArray();
            foreach (InstructionSegmentView segment in system.Concat(user).Where(segment => segment.Kind == "input" && inputs.All(input => input.Name != segment.InputName)))
            {
                Gap("SEGMENT_INPUT_UNDECLARED", "REFUSE", "Segment input " + segment.InputName + " has no input declaration.");
            }

            ResponsePolicy? policy = InvocationsSnapshot.ResponsePolicies.FirstOrDefault(candidate => candidate.InvocationOrdinal == invocation.InvocationOrdinal);
            ResponsePolicyView? response = policy == null ? null : new ResponsePolicyView(policy.ResponseFormat, policy.ResponseSchema, policy.ResponseSchemaSha256Utf16le, policy.SchemaCorroboration,
                policy.MaximumOutputTokens, policy.Temperature, policy.TimeoutMilliseconds, policy.MaximumAuthorizedAttempts, policy.ProviderSubstitutionAllowed);
            if (policy != null && policy.SchemaCorroboration != "PRESENT_IN_BODY")
            {
                Gap("RESPONSE_SCHEMA_" + policy.SchemaCorroboration, "WARN", "The declared response schema is " + policy.SchemaCorroboration + ".");
            }

            string? constructorScenario = InvocationsSnapshot.Constructors.FirstOrDefault(candidate => candidate.InvocationOrdinal == invocation.InvocationOrdinal && candidate.Role == "SYSTEM_CONSTRUCTOR")?.ConstructorPortNamespace;
            var instructions = new InstructionView(invocation.ConstructorOperationId,
                constructorScenario == null ? null : constructorScenario.StartsWith("sidefx:capability:", StringComparison.Ordinal) ? constructorScenario.Substring("sidefx:capability:".Length) : constructorScenario,
                constructor, assembly, system, user, inputs, response, ExpandedPromptUnavailable);

            ModelProviderView? provider = Providers.FirstOrDefault(candidate => candidate.ProviderId == invocation.ProviderId);
            if (invocation.ProviderId != null && provider == null)
            {
                Gap("PROVIDER_NOT_READ", "REFUSE", "Provider " + invocation.ProviderId + " was not read in this session.", "cross-reading");
            }
            else if (provider != null && provider.Availability != SemanticAvailability.Present)
            {
                Gap("PROVIDER_" + provider.Availability.ToString().ToUpperInvariant(), "REFUSE", "The provider reading for " + provider.ProviderId + " is " + provider.Availability + ".", "provider-details:" + provider.ProviderId);
            }

            ModelInspectionState state = invocation.OperationState != "RESOLVED"
                ? ModelInspectionState.Unresolved
                : gaps.Count == 0 ? ModelInspectionState.Resolved : ModelInspectionState.Partial;
            return new ModelInvocationView(
                invocation.InvocationOrdinal, invocation.InvocationId, invocation.Label, invocation.OperationId, invocation.Ordinal, invocation.ExecutionOperationPk, invocation.OperationState,
                invocation.RequestId,
                new ModelPortView(invocation.PortId, invocation.PortVersionPk, invocation.PortDigest, invocation.PlatformCapabilityId),
                invocation.ProviderId, invocation.ProviderState,
                new ModelProviderAuthorityView(invocation.ProviderAuthorities, invocation.BindingId, invocation.ProviderAuthorityId, invocation.ProviderKind, invocation.EndpointAuthorityDigest, invocation.CredentialReference),
                agreement, invocation.CompositionOperationId, invocation.CompositionOrdinal, invocation.CompositionLinkState, invocation.ConstructorOrdinal, invocation.ConstructorLinkState,
                invocation.SequenceState, model, instructions, state, gaps.ToImmutableArray());
        }

        // The capability details reading of the same session must place the operation identically.
        private string CapabilityAgreement(ModelInvocation invocation)
        {
            if (CapabilitySnapshot.Availability != SemanticAvailability.Present)
            {
                return "UNAVAILABLE";
            }

            ExecutionOperation? operation = CapabilitySnapshot.ExecutionOperations.FirstOrDefault(candidate => candidate.OperationId == invocation.OperationId);
            if (operation == null)
            {
                return "MISSING_OPERATION";
            }

            var differences = new List<string>();
            if (operation.Ordinal != invocation.Ordinal)
            {
                differences.Add("ordinal");
            }

            if (operation.PortId != invocation.PortId || operation.PortVersionPk != invocation.PortVersionPk)
            {
                differences.Add("port");
            }

            if (operation.ProviderOverlayId != invocation.ProviderId)
            {
                differences.Add("provider");
            }

            return differences.Count == 0 ? "AGREES" : "DISAGREES:" + string.Join(",", differences);
        }

        private ModelProviderView BuildProvider(ProviderSnapshot snapshot)
        {
            string providerId = ProviderIdOf(snapshot);
            ProviderIdentity? identity = snapshot.Provider;
            string? capabilityRole = CapabilitySnapshot.Providers.FirstOrDefault(candidate => candidate.ProviderId == providerId)?.ProviderRole;
            ImmutableArray<ModelProviderEngagementView> engagements = snapshot.Engagements.Where(engagement => engagement.CapabilityId == Bundle.CapabilityId)
                .OrderBy(engagement => engagement.EngagementKind, StringComparer.Ordinal).ThenBy(engagement => engagement.PortId, StringComparer.Ordinal).ThenBy(engagement => engagement.PortVersionPk)
                .Select(engagement => new ModelProviderEngagementView(engagement.EngagementKind, engagement.PortId, engagement.PortVersionPk, engagement.BindingId, engagement.ProviderAuthorityId,
                    engagement.ProviderKind, engagement.EndpointAuthorityDigest, engagement.EndpointTemplate, engagement.CredentialReference, engagement.CredentialValueState))
                .ToImmutableArray();
            (int rows, ImmutableArray<ProviderInstructionOwnerView> owners) = InstructionOwners(snapshot);
            return new ModelProviderView(providerId, snapshot.Availability, identity?.ProviderState, identity?.NamespaceId, identity?.DeclaredName, identity?.ProviderRole, capabilityRole,
                identity?.DefinitionDigest, engagements, rows, owners, snapshot.ProjectionDigest, snapshot.Revision.RevisionDigest);
        }

        // The provider reader's instruction-bearing rows, grouped by owner. They are evidence of what the
        // provider touches, not of which instructions the execution path uses; the declaration decides that.
        private (int Rows, ImmutableArray<ProviderInstructionOwnerView> Owners) InstructionOwners(ProviderSnapshot snapshot)
        {
            SemanticSection? section = snapshot.Sections.FirstOrDefault(candidate => candidate.Name == "provider_instructions");
            if (section?.Raw is not { } raw || raw.Kind != JsonValueKind.Array)
            {
                return (0, ImmutableArray<ProviderInstructionOwnerView>.Empty);
            }

            var inactive = new HashSet<(string?, string?)>(InvocationsSnapshot.InactiveTemplates.Select(template => (template.NamespaceId, template.DeclaredId)));
            var compositions = new HashSet<(string?, string?)>(InvocationsSnapshot.ConfigurationValues.Select(value => (value.TransformationNamespace, value.TransformationId)));
            var counts = new Dictionary<(string?, string?, string?), int>();
            using JsonDocument document = JsonDocument.Parse(raw.RawText);
            int total = 0;
            foreach (JsonElement row in document.RootElement.EnumerateArray())
            {
                total++;
                (string?, string?, string?) key = (Text(row, "owner_kind"), Text(row, "owner_id"), Text(row, "namespace_id"));
                counts[key] = counts.TryGetValue(key, out int count) ? count + 1 : 1;
            }

            ImmutableArray<ProviderInstructionOwnerView> owners = counts
                .OrderBy(pair => pair.Key.Item3 ?? string.Empty, StringComparer.Ordinal).ThenBy(pair => pair.Key.Item2 ?? string.Empty, StringComparer.Ordinal).ThenBy(pair => pair.Key.Item1 ?? string.Empty, StringComparer.Ordinal)
                .Select(pair => new ProviderInstructionOwnerView(pair.Key.Item1, pair.Key.Item2, pair.Key.Item3, pair.Value,
                    inactive.Contains((pair.Key.Item3, pair.Key.Item2)) ? "DECLARED_INACTIVE_TEMPLATE"
                    : compositions.Contains((pair.Key.Item3, pair.Key.Item2)) ? "ACTIVE_COMPOSITION_TRANSFORMATION"
                    : "NOT_IN_ACTIVE_VIEW"))
                .ToImmutableArray();
            return (total, owners);
        }

        private static void AddReadingGaps(List<ModelInspectionGap> gaps, string reading, SemanticAvailability availability, ImmutableArray<SemanticDiagnostic> diagnostics, SemanticRevision revision)
        {
            if (availability != SemanticAvailability.Present)
            {
                gaps.Add(new ModelInspectionGap("READING_" + availability.ToString().ToUpperInvariant(), "REFUSE", reading, "The reading is " + availability + ".", reading));
            }

            foreach (IGrouping<string, SemanticDiagnostic> group in diagnostics.Where(diagnostic => diagnostic.Severity != SemanticSeverity.Info).GroupBy(diagnostic => diagnostic.Code).OrderBy(group => group.Key, StringComparer.Ordinal))
            {
                gaps.Add(new ModelInspectionGap("PROJECTION_" + group.Key, group.First().Severity == SemanticSeverity.Error ? "REFUSE" : "WARN", reading,
                    group.Count().ToString(CultureInfo.InvariantCulture) + " diagnostic(s); first: " + group.First().Message, reading));
            }

            if (revision.Unpinned > 0)
            {
                gaps.Add(new ModelInspectionGap("UNPINNED_DEPENDENCIES", "INFO", reading,
                    revision.Unpinned.ToString(CultureInfo.InvariantCulture) + " dependenc" + (revision.Unpinned == 1 ? "y has" : "ies have") + " no digest in this reading: "
                    + string.Join(", ", revision.Dependencies.Where(dependency => dependency.Digest == null).Take(5).Select(dependency => dependency.Kind + " " + dependency.Id)), reading));
            }
        }

        private static string ProviderIdOf(ProviderSnapshot snapshot) =>
            snapshot.Provenance.Arguments.FirstOrDefault(argument => argument.Role == "identity")?.Value ?? string.Empty;

        private static string? Text(JsonElement row, string name) =>
            row.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

        /// <summary>
        /// The inspection as JSON. With <paramref name="includeCapture"/> false the view is stable: it
        /// omits capture time and duration and is what <see cref="InspectionDigest"/> hashes.
        /// </summary>
        public string ToJson(bool includeCapture = true)
        {
            var buffer = new ArrayBufferWriter<byte>();
            using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
            {
                writer.WriteStartObject();
                writer.WriteString("inspection", Assembler);
                writer.WriteString("capabilityId", Bundle.CapabilityId);
                writer.WriteString("state", State.ToString());
                if (includeCapture)
                {
                    writer.WriteString("inspectionDigest", InspectionDigest);
                }

                writer.WritePropertyName("capability");
                JsonSerializer.Serialize(writer, Capability, ViewOptions);
                writer.WriteStartObject("readings");
                WriteReading(writer, "modelInvocations", InvocationsSnapshot.Availability, InvocationsSnapshot.ProjectionDigest, InvocationsSnapshot.Revision, InvocationsSnapshot.Provenance, includeCapture);
                WriteReading(writer, "capabilityDetails", CapabilitySnapshot.Availability, CapabilitySnapshot.ProjectionDigest, CapabilitySnapshot.Revision, CapabilitySnapshot.Provenance, includeCapture);
                foreach (ProviderSnapshot provider in ProviderSnapshots)
                {
                    WriteReading(writer, "provider:" + ProviderIdOf(provider), provider.Availability, provider.ProjectionDigest, provider.Revision, provider.Provenance, includeCapture);
                }

                writer.WriteEndObject();
                writer.WriteStartObject("session");
                writer.WriteString("database", Bundle.Session.Database);
                writer.WriteNumber("estateModelPk", Bundle.Session.Basis.EstateModelPk);
                writer.WriteBoolean("estatePinned", Bundle.Session.Basis.Pinned);
                writer.WriteString("estatePublicationState", Bundle.Session.Basis.PublicationState);
                writer.WriteString("estateMappingManifestDigest", Bundle.Session.Basis.MappingManifestDigest);
                writer.WriteString("isolation", "SNAPSHOT");
                writer.WriteString("transactionOutcome", Bundle.Session.TransactionOutcome);
                if (Bundle.Session.DatabaseLogRecords is { } records)
                {
                    writer.WriteNumber("databaseLogRecords", records);
                }
                else
                {
                    writer.WriteNull("databaseLogRecords");
                }

                if (includeCapture)
                {
                    writer.WriteNumber("elapsedMilliseconds", Bundle.Session.ElapsedMilliseconds);
                }

                writer.WriteEndObject();
                writer.WritePropertyName("invocations");
                JsonSerializer.Serialize(writer, Invocations, ViewOptions);
                writer.WritePropertyName("providers");
                JsonSerializer.Serialize(writer, Providers, ViewOptions);
                writer.WritePropertyName("inactiveTemplates");
                JsonSerializer.Serialize(writer, InactiveTemplates, ViewOptions);
                writer.WritePropertyName("gaps");
                JsonSerializer.Serialize(writer, Gaps, ViewOptions);
                writer.WriteString("expandedRuntimePrompts", ExpandedPromptUnavailable);
                writer.WriteEndObject();
            }

            return Encoding.UTF8.GetString(buffer.WrittenSpan).Replace("\r\n", "\n");
        }

        private static readonly JsonSerializerOptions ViewOptions = new JsonSerializerOptions
        {
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() },
        };

        private static void WriteReading(Utf8JsonWriter writer, string name, SemanticAvailability availability, string? projectionDigest, SemanticRevision revision, SemanticProvenance provenance, bool includeCapture)
        {
            writer.WriteStartObject(name);
            writer.WriteString("procedure", provenance.Procedure);
            writer.WriteString("availability", availability.ToString());
            writer.WriteString("projectionDigest", projectionDigest);
            writer.WriteString("revisionDigest", revision.RevisionDigest);
            writer.WriteString("readerDefinitionDigest", provenance.Capture.ReaderDefinitionDigest);
            writer.WriteNumber("dependencies", revision.Dependencies.Length);
            writer.WriteNumber("unpinnedDependencies", revision.Unpinned);
            if (includeCapture)
            {
                // Exact transport bytes: readers emit some sections without a total order, so this hash can differ
                // between sessions of one revision while the projection digest does not. Capture evidence only.
                writer.WriteString("documentSha256", provenance.DocumentSha256);
                writer.WriteString("capturedAtUtc", provenance.Capture.CapturedAtUtc?.ToString("O", CultureInfo.InvariantCulture));
            }

            writer.WriteEndObject();
        }

        /// <summary>The summary table: one row per model invocation, then providers, inactive templates and gaps.</summary>
        public string ToSummaryText()
        {
            var text = new StringBuilder();
            ModelCapabilityView c = Capability;
            text.Append("Capability    ").Append(c.CapabilityId).Append("  (").Append(c.Identity?.Namespace ?? "namespace unavailable").Append(")\n");
            text.Append("Definition    ").Append(Nullable(c.SelectedDefinitionPk)).Append("  version ").Append(Nullable(c.SelectedVersionPk)).Append("  digest ").Append(c.DefinitionDigest ?? "unavailable").Append('\n');
            text.Append("Execution     authority version ").Append(Nullable(c.ExecutionAuthorityVersionPk)).Append("  digest ").Append(c.ExecutionAuthorityDigest ?? "unavailable")
                .Append(c.ExecutionAuthorityVersions is > 1 ? "  (" + c.ExecutionAuthorityVersions.Value.ToString(CultureInfo.InvariantCulture) + " versions selected)" : string.Empty).Append('\n');
            text.Append("Read basis    estate ").Append(c.Basis.ToString(CultureInfo.InvariantCulture)).Append(" (mutable pointer); revision ").Append(InvocationsSnapshot.Revision.RevisionDigest).Append('\n');
            text.Append("Session       SNAPSHOT, ").Append(Bundle.Session.DatabaseLogRecords?.ToString(CultureInfo.InvariantCulture) ?? "unobservable").Append(" estate log records, ").Append(Bundle.Session.TransactionOutcome.ToLowerInvariant().Replace('_', ' ')).Append('\n');
            text.Append("Declaration   model-invocations.v1 ").Append(c.DeclarationState).Append("  definition ").Append(Nullable(c.DeclarationDefinitionPk)).Append("  digest ").Append(c.DeclarationDigest ?? "none").Append('\n');
            text.Append('\n');
            var rows = Invocations.Select(invocation => new[]
            {
                invocation.Label ?? invocation.InvocationId ?? "?",
                invocation.ProviderId ?? "(none)",
                invocation.Model.ConfiguredModel ?? "(unresolved)",
                (invocation.Instructions.Constructor?.Procedure ?? "(none)") + (invocation.Instructions.Constructor is { BodyState: not "CURRENT" } procedure ? " [" + procedure.BodyState + "]" : string.Empty),
                invocation.State.ToString(),
            }).ToList();
            string[] header = { "Operation", "Provider", "Configured model", "Instruction source", "State" };
            int[] widths = header.Select((title, column) => Math.Max(title.Length, rows.Select(row => row[column].Length).DefaultIfEmpty(0).Max())).ToArray();
            string Row(IReadOnlyList<string> cells) => "| " + string.Join(" | ", cells.Select((cell, column) => cell.PadRight(widths[column]))) + " |\n";
            text.Append(Row(header));
            text.Append("|" + string.Join("|", widths.Select(width => new string('-', width + 2))) + "|\n");
            foreach (string[] row in rows)
            {
                text.Append(Row(row));
            }

            if (rows.Count == 0)
            {
                text.Append("(no model invocations: declaration ").Append(c.DeclarationState).Append(")\n");
            }

            text.Append("\nProviders\n");
            foreach (ModelProviderView provider in Providers)
            {
                ModelProviderEngagementView? engagement = provider.Engagements.FirstOrDefault(candidate => candidate.BindingId != null) ?? provider.Engagements.FirstOrDefault();
                text.Append("  ").Append(provider.ProviderId).Append("  ").Append(provider.Availability).Append("  role ").Append(provider.CapabilityRole ?? provider.ProviderRole ?? "none")
                    .Append("  definition ").Append(provider.DefinitionDigest ?? "none").Append("  binding ").Append(engagement?.BindingId ?? "none")
                    .Append("  instruction rows ").Append(provider.InstructionRows.ToString(CultureInfo.InvariantCulture)).Append('\n');
            }

            text.Append("\nInactive templates (inspectable; excluded from active instructions)\n");
            foreach (InactiveTemplateView template in InactiveTemplates)
            {
                text.Append("  ").Append(template.DeclaredId).Append("  ").Append(template.State).Append("  definition ").Append(Nullable(template.DefinitionPk))
                    .Append("  provider instruction rows ").Append(string.Join(", ", template.ProviderInstructionRows.Select(count => count.ProviderId + " " + count.Rows.ToString(CultureInfo.InvariantCulture)))).Append('\n');
            }

            if (InactiveTemplates.IsEmpty)
            {
                text.Append("  (none declared)\n");
            }

            List<ModelInspectionGap> visible = Gaps.Where(gap => gap.Severity != "INFO").ToList();
            text.Append("\nGaps          ").Append(visible.Count == 0 ? "none" : visible.Count.ToString(CultureInfo.InvariantCulture)).Append(Gaps.Length > visible.Count ? " (+" + (Gaps.Length - visible.Count).ToString(CultureInfo.InvariantCulture) + " informational)" : string.Empty).Append('\n');
            foreach (ModelInspectionGap gap in visible)
            {
                text.Append("  ").Append(gap.Severity).Append(' ').Append(gap.Code).Append("  ").Append(gap.Subject).Append(": ").Append(gap.Detail).Append('\n');
            }

            text.Append("Runtime prompts  expanded prompts are unavailable without invocation evidence\n");
            text.Append("State         ").Append(State).Append("   inspection digest ").Append(InspectionDigest).Append('\n');
            text.Append("Detail        sfx-semantics inspect-models ").Append(c.CapabilityId).Append(" --estate ").Append(c.Basis.ToString(CultureInfo.InvariantCulture)).Append(" --operation <label|id>\n");
            return text.ToString();
        }

        /// <summary>One invocation's instructions and provenance, in full.</summary>
        public string? ToOperationText(string selector)
        {
            ModelInvocationView? invocation = Invocations.FirstOrDefault(candidate =>
                string.Equals(candidate.InvocationId, selector, StringComparison.OrdinalIgnoreCase) || string.Equals(candidate.Label, selector, StringComparison.OrdinalIgnoreCase)
                || string.Equals(candidate.OperationId, selector, StringComparison.Ordinal));
            if (invocation == null)
            {
                return null;
            }

            var text = new StringBuilder();
            text.Append(invocation.Label).Append("  (").Append(invocation.OperationId).Append(", ordinal ").Append(Nullable(invocation.OperationOrdinal)).Append(", execution operation ")
                .Append(Nullable(invocation.ExecutionOperationPk)).Append(", ").Append(invocation.OperationState).Append(")\n");
            text.Append("  State        ").Append(invocation.State).Append("; capability reading ").Append(invocation.CapabilityAgreement).Append('\n');
            text.Append("  Port         ").Append(invocation.Port.PortId).Append(" v").Append(Nullable(invocation.Port.PortVersionPk)).Append(" (").Append(invocation.Port.PlatformCapabilityId).Append(")  digest ").Append(invocation.Port.Digest).Append('\n');
            ModelProviderAuthorityView authority = invocation.ProviderAuthority;
            text.Append("  Provider     ").Append(invocation.ProviderId).Append(" [").Append(invocation.ProviderState).Append("]  authority ").Append(authority.ProviderAuthorityId).Append(" (").Append(authority.ProviderKind)
                .Append(")  binding ").Append(authority.BindingId).Append('\n');
            text.Append("               endpoint authority ").Append(authority.EndpointAuthorityDigest).Append("  credential reference ").Append(authority.CredentialReference).Append(" (value never read)\n");
            text.Append("  Model        ").Append(invocation.Model.ConfiguredModel ?? "(unresolved)").Append("  endpoint ").Append(invocation.Model.EndpointTemplate).Append("  adapter ").Append(invocation.Model.AdapterIdentity).Append('\n');
            foreach (ModelConfigurationEntry value in invocation.Model.Values)
            {
                text.Append("    ").Append(value.Name).Append(" = ").Append(value.Value ?? "null").Append("  [").Append(value.State).Append("]\n");
                text.Append("      from ").Append(value.TransformationNamespace).Append('/').Append(value.TransformationId).Append(" definition ").Append(Nullable(value.TransformationDefinitionPk))
                    .Append(" digest ").Append(value.TransformationDigest).Append('\n');
                text.Append("      at ").Append(value.JsonPath).Append('\n');
            }

            text.Append("  Request      composed by ").Append(invocation.CompositionOperationId).Append(" (ordinal ").Append(Nullable(invocation.CompositionOrdinal)).Append(") [").Append(invocation.CompositionLinkState)
                .Append("]; sequence ").Append(invocation.SequenceState).Append("; request id ").Append(invocation.RequestId).Append('\n');
            InstructionView instructions = invocation.Instructions;
            text.Append("  Instructions constructed by ").Append(instructions.ConstructorOperationId).Append(" (ordinal ").Append(Nullable(invocation.ConstructorOrdinal)).Append(") [").Append(invocation.ConstructorLinkState)
                .Append("] -> scenario ").Append(instructions.ConstructorScenarioId).Append('\n');
            foreach (InstructionProcedureView? procedure in new[] { instructions.Constructor, instructions.Assembly })
            {
                if (procedure == null)
                {
                    continue;
                }

                text.Append("    ").Append(procedure.Role == "SYSTEM_CONSTRUCTOR" ? "constructor " : "assembly    ").Append(procedure.Procedure).Append("  body ").Append(procedure.BodyState)
                    .Append("  installed ").Append(procedure.InstalledBodySha256).Append(procedure.DeclaredBodySha256 == procedure.InstalledBodySha256 ? " (= declared)" : "  declared " + procedure.DeclaredBodySha256).Append('\n');
                if (procedure.PortId != null)
                {
                    text.Append("      port ").Append(procedure.PortNamespace).Append('/').Append(procedure.PortId).Append(" [").Append(procedure.PortState).Append("] ").Append(procedure.StatementCorroboration).Append('\n');
                    text.Append("      statement ").Append(procedure.PortStatement).Append('\n');
                }
            }

            foreach ((string title, ImmutableArray<InstructionSegmentView> segments) in new[] { ("System message", instructions.System), ("User message", instructions.User) })
            {
                text.Append("  ").Append(title).Append('\n');
                foreach (InstructionSegmentView segment in segments)
                {
                    if (segment.Kind == "static")
                    {
                        text.Append("    [").Append(segment.Ordinal.ToString(CultureInfo.InvariantCulture)).Append("] static, ").Append((segment.StaticText?.Length ?? 0).ToString(CultureInfo.InvariantCulture))
                            .Append(" chars, ").Append(segment.Corroboration).Append(", sha256-utf16le ").Append(segment.StaticTextSha256Utf16Le).Append('\n');
                        text.Append("        \"").Append(segment.StaticText).Append("\"\n");
                    }
                    else
                    {
                        InstructionInputView? input = instructions.Inputs.FirstOrDefault(candidate => candidate.Name == segment.InputName);
                        text.Append("    [").Append(segment.Ordinal.ToString(CultureInfo.InvariantCulture)).Append("] {").Append(segment.InputName).Append("}  ").Append(input?.Kind ?? "undeclared").Append(" input, ")
                            .Append(input?.ExpansionState ?? "UNDECLARED").Append('\n');
                        text.Append("        source: ").Append(input?.Source ?? "none").Append('\n');
                    }
                }
            }

            if (instructions.Response is { } response)
            {
                text.Append("  Response     ").Append(response.Format).Append("; schema ").Append(response.SchemaSha256Utf16Le).Append(" ").Append(response.SchemaCorroboration).Append('\n');
                text.Append("               ").Append(response.Schema).Append('\n');
                text.Append("               max ").Append(Nullable(response.MaximumOutputTokens)).Append(" output tokens, temperature ").Append(response.Temperature).Append(", timeout ")
                    .Append(Nullable(response.TimeoutMilliseconds)).Append(" ms, ").Append(Nullable(response.MaximumAuthorizedAttempts)).Append(" authorized attempt(s), provider substitution ")
                    .Append(response.ProviderSubstitutionAllowed == true ? "allowed" : "not allowed").Append('\n');
            }

            text.Append("  Expanded prompt  ").Append(instructions.ExpandedPromptState).Append('\n');
            text.Append("  Gaps         ").Append(invocation.Gaps.IsEmpty ? "none" : string.Empty).Append('\n');
            foreach (ModelInspectionGap gap in invocation.Gaps)
            {
                text.Append("    ").Append(gap.Severity).Append(' ').Append(gap.Code).Append(": ").Append(gap.Detail).Append('\n');
            }

            return text.ToString();
        }

        private static string Nullable(long? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "null";

        private static string Nullable(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "null";
    }

    /// <summary>Reads everything a model inspection needs in one SNAPSHOT session.</summary>
    public static class ModelInspectionReader
    {
        /// <summary>
        /// Reads the declared model invocations, the capability details and every named provider in one
        /// session, then rolls it back. The providers read are exactly those the estate reports.
        /// </summary>
        public static async Task<ModelInspectionBundle> ReadAsync(SemanticReadClient client, string capabilityId, long? estateModelPk = null, CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(client);
            ArgumentNullException.ThrowIfNull(capabilityId);
            await using SemanticReadSession session = await client.OpenSessionAsync(estateModelPk, cancellationToken).ConfigureAwait(false);
            SemanticRead invocations = await session.ReadModelInvocationsAsync(capabilityId, cancellationToken).ConfigureAwait(false);
            SemanticRead capability = await session.ReadCapabilityAsync(capabilityId, cancellationToken).ConfigureAwait(false);
            ModelInvocationsSnapshot projected = ModelInvocationsSnapshot.Project(invocations.Source, invocations.Capture);
            ImmutableArray<SemanticRead>.Builder providers = ImmutableArray.CreateBuilder<SemanticRead>();
            foreach (string providerId in CapabilityModelInspection.ProvidersOf(projected))
            {
                providers.Add(await session.ReadProviderAsync(providerId, cancellationToken).ConfigureAwait(false));
            }

            SemanticSessionOutcome outcome = await session.CompleteAsync(cancellationToken).ConfigureAwait(false);
            return new ModelInspectionBundle(capabilityId, invocations, capability, providers.ToImmutable(), outcome);
        }
    }
}
