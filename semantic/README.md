# SFX.Semantics

The read slices of the [Semantic Object Projection strategy](../docs/semantic-object-projection-strategy.md).
Installed SideFX readers are read inside one rolled-back SNAPSHOT session. CodeLightly projects
each reading into an immutable C# snapshot, and the results are verified against the live
estate without changing it.

```text
contracts/                            maintained  semantic-projection.v1 contracts (drafts)
semantic-projection.config.json       maintained  which contracts to generate, namespace and output
SFX.Semantics/Generated/              generated   CodeLightly output and its manifest; regenerate, never edit
SFX.Semantics/SemanticReadClient.cs   maintained  read client and one-transaction read session
SFX.Semantics/ModelInspection.cs      maintained  capability-to-model inspection assembled from snapshots
SFX.Semantics.Cli/                    maintained  read / inspect / verify / inspect-models / verify-models (sfx-semantics)
estate-probes/                        maintained  rolled-back estate probes (no commit twin)
regenerate.ps1                        maintained  offline, deterministic regeneration
```

The root `SFX.DAL` project excludes this tree (see [Directory.Build.props](../Directory.Build.props)).

## Readings

| Contract | Reader | Typed | Retained |
| --- | --- | --- | --- |
| [capability-details](contracts/capability-details.semantic-projection.v1.json) | `analysis.read_capability_details`, document mode | summary, scenarios, contracts, operations, ports, bindings, providers | 38 sections; 10 declared order-free |
| [provider-details](contracts/provider-details.semantic-projection.v1.json) | `analysis.read_provider_details`, 11 declared result sets | identity, configuration, engagements | 8 sets, including 2,028 instruction-bearing rows; `credential_value` withheld |
| [capability-model-invocations](contracts/capability-model-invocations.semantic-projection.v1.json) | `analysis.read_capability_model_invocations` (estate-owned) | all 9 sections | none |

Each snapshot carries:
- **Availability:** `Present`, `Absent` (a declared refusal, or a root the reader reports
  absent) or `ContractMismatch` (any error, including an undeclared refusal or a reported basis
  that differs from the bound one).
- **Identity and provenance**, plus a revision vector. The estate number is a mutable pointer.
  The revision vector records the reader body digest and every dependency's digest, including
  the capability version digest the read session pins in the same snapshot.

## Model inspection

Use the [operational runbook](../docs/model-inspection-operations.md) for ordinary
provider, model, and instruction questions. Take one live capture and use its
saved bundle for operation details. Record actual unanswered questions, latency,
and manual fallbacks to guide subsequent changes.

```powershell
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- inspect-models request-capability-from-objective-v3 --estate 34
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- inspect-models request-capability-from-objective-v3 --estate 34 --operation select
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- inspect-models request-capability-from-objective-v3 --estate 34 --save-source <bundle.json>
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- inspect-models --source <bundle.json> [--operation select] [--json]
```

The invocation is the central object. For each declared model call, the inspection shows:
- the operation and its position, the port, and the provider with its authority,
- the configured model, with the definition, digest and JSON path that supply it,
- its own instructions: the constructor and assembly procedures at their installed digests,
  ordered static and dynamic segments, and the response policy.

Two calls through `google/gemini-select` therefore carry different instructions.

Authority for these relationships is the estate declaration
`sidefx:capability:request-capability-from-objective-v3/model-invocations.v1`, read through
`analysis.read_capability_model_invocations`. Both were installed by `sfx-embody`
`sql/migrations/declare-capability-model-invocations.commit.sql`. Nothing parses SQL or matches
names at read time. Static text is declared data, pinned by the constructor body digest and
corroborated against that body.

Old `build-agent-*` templates stay inspectable, with their definitions and provider instruction
rows, and are excluded from the active view. Dynamic catalog, schema and result inputs are
named, and expanded runtime prompts are reported as
`UNAVAILABLE_WITHOUT_INVOCATION_EVIDENCE`. A saved bundle replays offline to a byte-identical
view and the same inspection digest.

## Commands

Reads use the `sidefx-connection-string` Machine setting and never print it.

```powershell
./semantic/regenerate.ps1 -CodeLightlyRoot <Codelightly> -ReceiptPath verification/<date>-semantic-generation.json
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- verify --reads 6 --receipt verification/<date>-semantic-capability-slice.json
dotnet run --project semantic/SFX.Semantics.Cli -c Release -- verify-models --estate 34 --receipt verification/<date>-semantic-model-inspection.json
# from sfx-embody: the rolled-back estate probe of explicit states
node ../scenario-driven-architecture/languages/typescript/src/kernel/bootstrap/run-migration.mjs ../sfx-dal/semantic/estate-probes/model-invocation-states.preflight.sql
```

## Evidence

- [Generation, 2026-10-10](../verification/2026-10-10-semantic-generation.json): three contracts,
  two independent generations byte-identical, no drift, and both builds pass.
- [Capability slice, 2026-10-10](../verification/2026-10-10-semantic-capability-slice.json):
  all 18 checks pass. They include the closed review findings (basis, refusal validation,
  incomplete references) and six repeated reads with one revision and one projection digest.
- [Model inspection, 2026-10-10](../verification/2026-10-10-semantic-model-inspection.json): the latest run recorded one unexplained estate log record in one read session (7 of 9 checks pass); the run before it passed
  all 9 checks. They cover the three v3 model calls and two providers, traceable values,
  inactive templates, dynamic inputs, explicit states, deterministic replay, single-session
  agreement and an unchanged estate.
- [Estate state probe](../verification/2026-10-10-model-invocation-state-probe.json): the estate
  reader reports `MISSING`, `STALE`, `MISMATCH`/`OUT_OF_ORDER`, `PATH_MISSING`,
  `NOT_FOUND_IN_BODY`, `SEGMENT_INPUT_UNDECLARED` and `CONFLICTS_WITH_ACTIVE` for planted defects.
  It is rolled back.
- The October 9 receipts remain as the first slice's record.

## Limits

- **Readers emit some rows in no fixed order.** The capability and provider readers emit some
  sections without a total `ORDER BY`. The contracts declare those sections order-free, and
  document byte hashes are capture evidence only. Fixing the order in the estate readers would
  remove the ambiguity at its source.
- **The model declaration covers one capability.** It exists for
  `request-capability-from-objective-v3` only. Other capabilities report `NOT_DECLARED`.
- **Out of scope:** expanded prompts, model execution, prompt editing, provider switching,
  hosted endpoints and other language emitters.
- **The contracts are reviewed drafts.** An estate-owned export would replace them.
