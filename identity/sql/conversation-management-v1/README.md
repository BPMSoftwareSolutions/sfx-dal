# OV3 conversation management — SQL delivery

This package installs durable conversation state in **sfx-identity** and two declared workflow capabilities in **sidefx**. It uses the existing principal identity, data-source invocation and OV3 execution contracts. No consumer, host API or runtime kernel change is included or required for these new capability calls.

**The execution entry is `run-conversation-turn`. Existing direct calls to `request-capability-from-objective-v3` do not gain managed continuity automatically.** Open a conversation once, then send its subsequent messages through the managed entry. The existing entry remains the nested OV3 executor.

## Execute

Use the normal database administrator connection. Run each script as a complete batch in the database named below. The installation scripts each commit their own transaction and roll back on failure; do not wrap them in an outer transaction. There is no cross-database transaction: if the estate installation fails, the identity installation remains safe to retain and the estate script can be retried.

| Order | Script | Database | Effect |
|---|---|---|---|
| 1 | `01-install.sql` | `sfx-identity` | Add identity registry, conversation tables and procedures |
| 2 | `02-estate-install.sql` | `sidefx` | Declare, select and expose both managed capabilities through existing writers |
| 3 | `03-verify.sql` | `sfx-identity` | Run behavioral checks; roll back all fixtures |
| 4 | `04-identity-readback.sql` | `sfx-identity` | Check installed objects and counts |
| 5 | `05-estate-readback.sql` | `sidefx` | Check both capabilities are selected and discoverable |

The verification script uses Sidney's existing principal `565de6d4-ebcd-408b-9359-04d21dc62183`. Change its one `@principal` variable if running in a different identity database. Installation has no user-specific IDs or model credentials to fill in. It expects database names exactly as listed, SQL Server/Azure SQL JSON support, and the already-installed estate declaration writers. Rerunning preserves conversation history.

If you installed the original delivery, run `06-repair-turn-preparation.sql` in **sidefx**. It corrects a live-discovered preparation bug: adding `action` to the reader's input-sized parameter truncated the JSON. The repaired workflow expands into a separate `nvarchar(max)` variable. The current `02-estate-install.sql` already contains this correction. No identity reinstall is needed. `05-estate-readback.sql` also contains the explicit binary identifier collation correction.

## What is installed

- **Conversation:** stable identity, owning principal, immutable original objective, retained source references and explicit completion state.
- **Thread:** parent lineage, assigned responsibility, optional agent/model-role binding, explicit inherited context, checkpoint, revision and continuation state. A child does not automatically copy the parent transcript.
- **Turn:** stable retry identity, ordered user message, exact prepared context, OV3 request, returned response and optional observed inference evidence. Each new turn uses its own OV3 inference-conversation ID while retaining the canonical conversation and thread IDs.
- **Model identity:** provider reference, declared version, definition and digest. Model registration does not provision API keys or claim a separate key is a context boundary.
- **Workflow binding:** immutable composition reference (`workflow_id`, revision, scenario and operation), role and model identity. Seeded roles are coordinator, evidence-selector, author, reviewer and executor.

The canonical authority JSON documents accompany the estate SQL for review. The SQL embeds the same documents and uses `model.declare_capability_document`, `model.repoint_capability_feature` and the installed tooling/inquiry writers. These establish the estate feature/DSL representation through the existing pipeline; local files are delivery artifacts, not the runtime authority.

## Invoke

Use the existing generic capability invocation surface in namespace `sidefx:capabilities`. Each capability's root scenario has the same name as its capability. The UUIDs below are examples; generate a new conversation UUID for a new objective and a new turn UUID for each new message. Reuse a turn UUID only to retry that exact message.

First invoke **`manage-conversation`**:

```json
{
  "action": "open",
  "principalId": "565de6d4-ebcd-408b-9359-04d21dc62183",
  "conversationId": "6a160a7f-a51f-4e3a-901f-c7523e6242fa",
  "objective": "Fulfil the original request using its retained source material.",
  "sourceRefs": []
}
```

Populate `sourceRefs` with the already-retained artifact references for the actual request. This retains references; it does not upload files, copy large report bytes into the prompt or invent missing history.

Then invoke **`run-conversation-turn`**:

```json
{
  "principalId": "565de6d4-ebcd-408b-9359-04d21dc62183",
  "conversationId": "6a160a7f-a51f-4e3a-901f-c7523e6242fa",
  "turnId": "96e2af40-09f5-4f43-85fd-7b8a4a35918d",
  "message": "Continue the original request from its retained evidence."
}
```

For the next message, keep `conversationId`, change `turnId`, and supply the new message. Omitted `threadId` selects the root thread, whose ID equals the conversation ID. The returned `conversationId` is canonical; the nested `response.conversationId` is the turn's inference ID. An `ANSWERED` response does not mark the overall objective complete.

`manage-conversation` exposes these actions:

| Action | Additional fields and behavior |
|---|---|
| `list` | Principal-owned list; optional `pageSize` and `afterConversationId` cursor |
| `read` | `conversationId`, optional `threadId`, `afterSequence` and `pageSize`; returns revisions, turns, children and checkpoint |
| `fork` | Existing `conversationId`, new `threadId`, `parentThreadId`, `responsibility`; optional explicit `context`, `agentId`, `bindingId` |
| `checkpoint` | Conversation/thread, `expectedRevision` from `threadRevision`, `coveredThroughSequence`, and `checkpoint` object containing `summary`, `obligations` and `evidenceRefs` arrays |
| `interrupt` | Conversation/thread and unresolved `turnId`; records that reconciliation is needed |
| `reconcile` | Conversation/thread, `turnId`, `expectedRevision`, and `reconciliation` with disposition `NO_EFFECTS_VERIFIED` or `PARTIAL_EFFECTS_RECORDED`, nonempty `evidenceRefs`, and `nextAction` |
| `resume` | Conversation/thread and `expectedRevision`; requires prior turns to be resolved |
| `close` | Conversation/thread, `expectedRevision`, state `COMPLETED` or `CANCELLED`, and `completion` basis; completion requires evidence and no outstanding checkpoint obligations or open child threads |

`prepare` and `record` are also available to estate orchestration; `run-conversation-turn` composes them automatically. A completed turn replay returns the retained result without rerunning OV3. An interrupted or ambiguous dispatch is retained for readback and reconciliation before another execution. This is not a claim of exactly-once effects across databases or external systems. Read a fork's thread before retrying creation after an uncertain response.

## Context and attribution

Context preparation uses the original objective, thread responsibility, source references, explicit inherited context, checkpoint and turns after that checkpoint. Full history stays in the database. OV3/System One can select evidence and record a compact checkpoint through the declared action. Optional `maxContextChars` refuses an oversized request rather than truncating retained data. It is a UTF-16 character budget, not a tokenizer measurement. Automated selection/scheduling is not added by this package; without checkpoints, unconsumed turn history grows.

Register verified model identities with `[identity].register_conversation_model`, then link composition and role using `[identity].register_conversation_binding`. Both procedures expose named parameters in `01-install.sql`; new versions/bindings require new identities. Supply the resulting `bindingId` on `open` or `fork`. No guessed provider/model versions are seeded.

Bindings record **requested attribution/configuration**. The existing OV3 workflow still resolves its configured provider. This package does not make that provider switch models based on a binding, nor does it fabricate actual model/version testimony. `inferenceEvidence` can retain actual provider receipts when supplied by the invoking workflow.

## Boundaries and operational behavior

The identity procedure compares every access with the stored owner. The authenticated caller boundary must supply/validate `principalId`; a caller-supplied UUID is not authentication. Do not expose these SQL procedures as an anonymous user API. Live readback found the existing identity data source executes as `dbo`. Installation additionally grants the existing `sfx_evidence_runtime` role execute permission on `conversation.manage` if that role exists, without broadening its other rights. Model/binding registration remains an operator action.

No legacy conversation is silently migrated and no front-end session is silently replaced. Retained objectives/references can be adopted by opening a managed conversation and supplying a checkpoint with provenance. No background process, continuous resumption loop, provider credentials, destructive teardown or browser UI migration is installed. Closure records the caller's evidence-backed assertion; SQL does not independently judge whether an objective was semantically fulfilled.

Digests in identity tables are SHA-256 over SQL `nvarchar` UTF-16LE bytes. They are not interchangeable with artifact-store UTF-8 digests. The download's checksum manifest separately hashes actual file bytes.

## Validation

The identity installation and repeat installation were executed successfully in a disposable SQL Server LocalDB database with the required principal fixture. The rollback-only suite covers Unicode/large objectives, open replay, child isolation, fresh inference IDs, recorded-result replay, checkpoint retention, interrupted-turn recovery, closed-state replay, pending-turn refusal, context budget refusal, stale revisions, conflicting turn payloads, completion evidence and owner isolation.

SQL syntax and embedded estate statement checks passed. After the owner's installation and script 06 repair, live acceptance passed through the published capability interface: a managed turn returned and retained `CM_CONTINUITY_OK`; replay returned the identical result and dispatched `manage-conversation` with zero OV3 inference cells; a second turn received the prior turn's history and returned the expected reply. Independent readback found exactly two returned turns. The acceptance conversation was explicitly completed with the retained run references as evidence. See `validation.json` for all run IDs. This proves the managed capability path; the existing front-end entry still needs to call that path to gain continuity. No live schema changes were applied by the assistant.

Source ownership: identity SQL lives in `sfx-dal/identity/sql/conversation-management-v1/`; estate declarations live in `sfx-embody/sql/conversation-management-v1/`. The downloadable package combines copies for execution convenience.
