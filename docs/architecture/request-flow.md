# Request flow

This describes implemented behavior, not a successful reliability qualification. See [reliability status](../development/reliability-status.md) for the failed held-out gate.

## Session and turn lifecycle

`AppServices.newSession` supplies repositories, scheduler, pending interactions, operation journal and the selected model/rules engine. `start()` loads or falls back and enters listening. A turn captures one clock value so interpretation and execution agree about “now”. Cancellation is checked before committing; committed writes retain their receipts.

The shared pipeline is:

```text
user turn + operation ID
  → authorization + routing
  → CandidatePlan (call, effects, pending changes, evidence)
  → validatePlan
  → ToolExecutor + ExecutionReceipt
  → persisted reply
```

The legacy interpreter is the default. `CORENYTH_INTERPRETER=unified` selects the coordinator and plan-v2 contract for comparison. Both share validation, execution, receipts and journaling; only the selected interpreter executes a turn.

## Interpretation and context

App-grounded routes handle explicit memory commands, pending target/time answers, arithmetic, completion-state questions, certain calendar moves and confirmation questions. Follow-through routes handle daily schedules, event details/outcomes, progress reports, briefings and cancellation clarification. These routes build candidates or pending changes rather than directly performing domain writes.

Remaining requests can call the local model for a grammar-constrained semantic plan. Each intent's grammar allows only its parser fields. Plan-v2 adds authorization labels and progress/outcome/detail intents, but a model label never supplies permission to act.

- The app reads authorization from the user's words, including polite requests; a question mark alone does not forbid an action.
- Relevant task rows and explicit older IDs are ranked before applying the context cap. Task state comes from SQLite, never an old assistant list.
- Active relevant personal memories reach both planning and reply prompts. Durable personal statements are excluded from historical replay so deletion/correction is respected.
- The current request is excluded from “earlier” user context. Prompt shrinking retains the request, selected task fields and pending interaction.
- `temporal.dart` resolves whole-message time evidence. A conflicting/unsupported constraint outranks a valid-looking model substring. The app asks instead of guessing.
- Model-generated action titles and list ranges must agree with the request. Invalid or rejected plans use the rules fallback; unavailable-model language coverage is degraded.

## Validation, execution and replies

`validatePlan` checks authorization and field/target evidence for both rule and model candidates. The executor reports committed/replayed/read-only/no-write/failed results and scheduler status. Confirmations follow persisted state and receipts, not an unvalidated model success sentence. “Scheduled” means accepted by the scheduler, not proof that a person saw an alarm.

Optional conversational wording is a separate bounded reply call over supplied facts. Action claims, ungrounded numbers and parroting are rejected, with a deterministic fallback. These checks still do not guarantee general factual or conversational quality; measured wording limitations are documented in the evaluation report. The chat displays the final validated response rather than an executable draft.

The operation journal persists validated actions and receipts. Retrying a committed operation recovers existing stamped rows rather than creating another reminder or resolving “in ten minutes” against a later restart clock. Startup recovery skips active/recent operations. A new request receives a distinct operation ID.

## Pending interactions and model lifecycle

Missing-time drafts use the reserved `main` key in `pending_clarifications`, allowing another chat or restart to answer them. Legacy per-chat drafts remain readable. Target picks use `pick:<chat>`, retaining tool, arguments, candidate IDs and asked-at time across restart; they expire after six hours. Meeting details/outcomes remain task-bound through `awaiting`.

`close()` cancels an in-flight turn and ends the session while the shared model can stay resident. Model load/release is serialized by `AppServices`; memory pressure releases the model for later reload. Selected model, resident model and last-answer source are separate UI states. The loader uses a constant rotating arc and honors reduced motion.

Diagnostics record timing, route, fallback codes, prompt fingerprint, build/model identity, validation and receipt status without raw personal messages. Actual phone lifecycle and delivery checks remain open.
