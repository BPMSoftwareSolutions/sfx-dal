# Model inspection in daily operation

Use the semantic CLI first to answer which providers, configured models, and
instructions `request-capability-from-objective-v3` uses. The supported flow
returns three declared model calls and their source evidence. Its scope is stored
configuration and instruction construction; a fully expanded prompt or the model
version reported by a vendor requires evidence from a particular invocation.

## Read once and follow the evidence

Run these commands from the `sfx-dal` repository root. Reads use the configured
`sidefx-connection-string` Machine setting.

```powershell
$captureDir = Join-Path '.tmp/inspect-models' ([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null

dotnet run --project semantic/SFX.Semantics.Cli -c Release -- inspect-models request-capability-from-objective-v3 --save-source "$captureDir/bundle.json"
```

The live read resolves the current estate. Add `--estate 34` when the question
specifically concerns that estate. The summary provides the operations, provider
identities, configured models, instruction constructors, and any reported gaps.

Inspect each step from the saved capture, so follow-up questions reuse the same
evidence and do not repeat the provider reads:

```powershell
dotnet run --project semantic/SFX.Semantics.Cli -c Release --no-build -- inspect-models --source "$captureDir/bundle.json" --operation select
dotnet run --project semantic/SFX.Semantics.Cli -c Release --no-build -- inspect-models --source "$captureDir/bundle.json" --operation construct-request
dotnet run --project semantic/SFX.Semantics.Cli -c Release --no-build -- inspect-models --source "$captureDir/bundle.json" --operation summarize
```

The detail view supplies instruction segments, dynamic inputs, model source paths,
procedure digests, and response policy. Use `--json` with the saved source for the
complete structured inspection. Keep captures unedited and in `.tmp/`. Take a new
live capture when the question requires updated estate state.

## When a question remains unanswered

Exit code `0` means the inspection reports `Resolved`; `3` means it reports a
partial or unresolved result. Read the named gaps and retain the useful evidence.
A runtime failure or unmatched operation selector returns `1`.

If the result does not answer the operational question, follow its source
references through the existing readers or definitions and record that manual
fallback. Capabilities without the declaration report `NOT_DECLARED`. Requests
for actual runtime prompts need invocation evidence. Neither case should produce
a guessed answer.

## Let use determine the next change

For an operational observation, record the question, whether it was answered,
elapsed live and follow-up times, exit codes, any fallback, and the concrete effect
on the task. Keep raw bundles and instruction payloads out of the observation
record; link the source revision and inspection digest instead.

A failed task, misleading result, recurring workaround, or measured cost can
justify a prioritized change. Record its impact, frequency, and available
workaround before assigning a priority. The bundle-consistency and completeness
probes from review remain unprioritized observations; ordinary use proceeds.

Verification commands and estate probes are development tools. They are not part
of the normal question-and-answer flow.

The [first operational observation](../verification/2026-10-10-model-inspection-operations.json)
records use of this workflow for the provider and instruction question. It was
answered without manual fallback: the live capture took 49.8 seconds and each
saved-source detail took 1.3-1.5 seconds. This is one observed task, not a latency
benchmark. Reuse the capture for related questions and observe whether live-read
waiting materially affects subsequent work before assigning it a priority.
