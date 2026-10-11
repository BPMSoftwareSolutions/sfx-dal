# Operational inspection

For questions about model providers, configured models, or instructions in
`request-capability-from-objective-v3`, use `inspect-models` as the first read.
Follow [the operational runbook](docs/model-inspection-operations.md). Save the
live bundle under `.tmp/` and answer follow-up questions from that same capture.
Refresh it when the question requires current estate state.

Use the existing readers or definition evidence when the CLI cannot answer the
question. Record the unanswered question, observed effect, and manual fallback.
Other capabilities currently have no model-invocation declaration; report that
scope directly.

Prioritize changes from operational evidence: a failed task, misleading answer,
repeated manual work, or measured latency/cost that affects use. Synthetic probes
are unprioritized observations until their operational impact is established.
Do not turn speculative hardening into a prerequisite for using the working flow.
Do not run verification suites or estate mutation probes as part of an ordinary
inspection request.

The root DAL and `semantic/SFX.Semantics/Generated/` are generated output. Follow
the repository README for maintained sources and regeneration. Keep saved source
bundles in ignored `.tmp/`; retain only bounded operational observations in
`verification/`.
