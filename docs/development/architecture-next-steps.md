# Corenyth: next steps after the Mem0 and Hermes study

Date: 29 October 2026. Reviewed source revision: `0ee7905`, including the existing untracked `CORE_RULES.md` and architecture study. This document retains the proposed sequence and records partial implementation and verification in the checkpoint below.

## Detailed execution plan

The [architecture execution plan](architecture-execution-plan.md) expands this roadmap into concrete packages, state transitions, evaluation contracts, migration strategy and release gates against revision `abb3420`. Use it for the next implementation cycle; the checkpoint below remains historical evidence.

## Direction

Keep Corenyth an offline personal assistant: deterministic code owns authorization, dates, storage, scheduling and execution; the small local model interprets phrasing and provides bounded personality. Adopt the study's memory and lifecycle principles by improving the existing implementation. Do not replace it with Mem0, Hermes, a vector service, or a new agent loop.

The new [core rules](../../CORE_RULES.md) supply the product boundary: reminders, alarms, tasks, notes, schedules and saved personal facts; concise answers; a first-request scope response without inference; and a repeated out-of-scope request allowed through to the local model. A conservative subset is now implemented in `CorePolicy`; see the checkpoint and request-flow documentation for its limits.

## What the study misses about the current app

| Study proposal | Source evidence today | Next action |
|---|---|---|
| Create durable tasks and scheduling | `lib/data/db.dart`, `lib/data/repos.dart`, `lib/services/reminder_scheduler.dart`, native `Proactive.kt` already implement persistence, pending scheduling intents and OS alarms. | Verify delivery and recovery; preserve existing tables and widget contracts. |
| Introduce a structured execution lifecycle | `lib/assistant/session.dart` already builds candidates, validates them and commits receipts through an operation journal. | Keep one shared execution boundary for all routes. |
| Add deterministic date interpretation | `lib/assistant/temporal.dart` and `rule_engine.dart` already resolve supported expressions and clarify unsupported/conflicting ones. | Close specific coverage gaps, particularly day-only calls; do not create a second parser. |
| Add personal memory and replacement | `MemoryRepo` already has FTS retrieval, provenance, active/superseded records and transactional slot-based replacement. | Improve indexing and explicit fact semantics incrementally. |
| Adopt FTS5 | Production uses FTS4 deliberately for Android compatibility. | Retain FTS4. A different SQLite build needs a separate compatibility justification. |
| Implement stable-prefix caching | `Prompt._renderPlan` separates system and dynamic input; native generation already reuses the common token prefix. | Measure token counts and reuse, then shorten prompts without losing accuracy. |
| Make deterministic routes instantaneous | Some routes await `_moodOnlyCall` before saving the final reply; a display callback now precedes that optional call. `_ModelBudget` permits one plan and up to two reply calls. | Measure actual calls per route and remove model work from the confirmation critical path without fabricating mood. |
| Configure WAL | `openAppDb.onConfigure` explicitly sets foreign keys only. | Inspect effective settings on each Android connection before deciding a consistent journal policy. |

The data-model documentation has been updated to schema v9, including per-message mood records. Source and fresh measurements take precedence over older status prose.

## Claims that must remain hypotheses

- The study's <5 ms routing, <1 second warm inference, 3–4 second cold inference, 90% retrieval quality and 100% command accuracy are not established Corenyth measurements.
- Its accuracy arithmetic is inconsistent: 12 existing passes plus 14 repaired failures gives 26/34, not 29/34. Neither outcome can be inferred without running the cases.
- The recorded 12 pass / 18 fail / 4 incomplete held-out run used an older prompt/model configuration. It demonstrates a failed historical gate, not the current tuned model's measured accuracy.
- Four tools is not an established model limit and would omit existing task operations. Keep the supported capability contract; evaluate compact intent schemas instead.
- Do not copy transcript deletion from a rolling memory buffer into user-visible conversation storage. Bound inference context while retaining saved chat history.
- A KV cache improves reused prefixes, not the first cold evaluation. Shorter prompts and load/runtime improvements need separate measurements.
- Selected observation-date and reference-only framing logic was inspected in the supplied local Mem0/Hermes checkouts; the complete upstream study was not independently re-audited; the study is design input, not verified upstream documentation.

## Implementation sequence

### 1. Establish today's baseline and product contract

Start here before prompt or model changes.

- Record source identity, model checksum, prompt fingerprint, interpreter mode, runtime context size and device information.
- Run existing unit/regression checks and the development corpus with rules only and the actual allowlisted tuned model. Keep pre-existing failures explicit. Align host context size with the phone's 2048-token setting or label any discrepancy.
- Extend the evaluation runner to execute the existing 23 multi-turn scenarios and close incomplete checks. The current runner documentation explicitly says these scenarios are not executed as a corpus.
- Record route, model-call count, input/output tokens, reused tokens, load time, time to visible confirmation, complete-turn latency and peak RAM. Use metadata only, without raw personal content.
- Specify distinctions between an alarm, a reminder and a saved note using current supported behavior; do not advertise a capability solely because the new core rules name it.
- Update the architecture/status docs to reflect v9 and current mood-related inference behavior.

Exit: reproducible development baseline, an explicit list of incomplete measurements, and product examples for every core-rules requirement. Do not inspect held-out inputs to design fixes.

### 2. Implement the core policy and a genuinely fast command path

Primary files: `lib/assistant/rule_engine.dart`, `lib/assistant/session.dart`, shared planning/validation code and route tests.

- Recognize core and pending-interaction routes before applying the scope policy. Preserve requests such as “plan my day” and “remind me to explain code to Sam”.
- Return the core-functionality response for clearly out-of-scope first requests, without any plan, prose or mood inference call. Track the refused topic within the conversation; permit an immediate same/similar repeat; reset on an unrelated turn and avoid leakage across chats.
- Add a bounded concise-output policy, with explicit-detail and repeated-request exceptions. Preserve complete action confirmations and clarification questions; never truncate essential dates or results.
- Route confidently recognized commands through existing `CandidatePlan` validation and receipts. Ambiguity, negation and compound requests must not become speculative writes. Preserve the model's role for phrasing outside the deterministic grammar.
- Publish and persist a committed deterministic confirmation before optional mood inference. Preserve model-origin mood and turn identity; show the existing unknown/calm fallback until a valid reading arrives. Serialize optional work with native inference, cancel stale work on a new turn, and prevent late updates from attaching to another message. Scope refusals must skip this work entirely.

Exit: zero model calls for first scope refusals; correct repeat/reset behavior; no unauthorized or duplicate writes; deterministic confirmation under the existing proposed 500 ms device target. Report optional mood completion separately. Keep mascot/turn-identity regression coverage.

### 3. Close temporal and clarification gaps

Primary files: `lib/assistant/temporal.dart`, `rule_engine.dart`, pending interaction/session handling.

- Treat “I have a call on Sunday” as needing a time, preserving the resolved day across the clarification and restart. Do not silently choose 9 AM.
- Reuse the captured turn clock. Define supported weekday semantics explicitly, and add selected missing forms only with clear calendar rules and conflict tests.
- Ground any date-bearing durable fact to its observation time and timezone. Do not store a relative expression as a timeless fact. Leave an ambiguous date unresolved and ask.
- Use local calendar boundaries for calendar days; distinguish elapsed durations from calendar-day arithmetic. Test midnight, month/year boundaries and timezone/DST behavior where supported.

Exit: regression tests prove exact stored timestamps, no-write clarification, restart continuation and consistent results across the selected interpreters.

### 4. Reduce model cost without changing the safety contract

Primary files: `lib/assistant/engine.dart`, `session.dart`, native `llama_jni.cpp`, development evaluation tooling.

- Benchmark a shorter static prompt against the baseline. Keep grammar, authorization evidence and essential instructions. Do not remove examples merely to meet an arbitrary 150-token target.
- Keep changing time, tasks and retrieved memories out of the reusable prefix. Measure common-prefix loss when tasks, tone or profile change.
- Use actual tokenizer counts and reserve response capacity inside 2048 tokens. Prioritize current input, pending state and relevant task identifiers; then bounded facts and recent conversation. A four-turn limit alone does not bound tokens.
- Frame retrieved memories and old context as reference data, never executable instructions. Do not reintroduce deleted facts from old messages or use old assistant task lists as current state.
- Aim for one inference call on normal model-assisted turns. Enumerate legitimate fallback/mood exceptions and measure their cost; avoid adding a second model confirmation after a successful tool.

Exit: no development accuracy/safety regression; measured cold and warm p50/p95 improvement; correct overflow behavior and preserved context over a 20-turn scenario. Do not promise a latency number before phone testing.

### 5. Harden memory and persistence incrementally

Primary files: `lib/data/db.dart`, `lib/data/repos.dart`, memory extraction/retrieval, database tests and native readers.

- Add indexed normalized content hashes if baseline volume justifies removing the current full dedupe scan. Backfill safely; retain text comparison to handle collisions and define normalization explicitly.
- Persist recognized subject/attribute slot keys where useful. Preserve provenance and supersession links rather than overwriting unrelated facts. Keep general notes separate from structured preferences and live task state.
- Save explicit personal facts deterministically. Store declarative statements, not behavioral directives. Do not add background model extraction until missed-fact evidence justifies its complexity and battery cost.
- Specify durable/global facts versus conversation-bound pending context before adding scope columns or expiry. Existing cross-chat personal facts should remain available; temporary drafts must not become permanent preferences.
- Inspect journal mode and synchronization for Dart, widget and headless connections. If adopting WAL, configure compatible connections and a checkpoint policy, measure contention, and test interruption recovery. Choose durability tradeoffs explicitly; a journal-size setting alone is not a complete WAL growth policy.
- Test fresh databases and upgrades from supported older versions, active-only retrieval, correction, deletion, restart and concurrent readers. Preserve native widget expectations and operation idempotency.

Exit: memory correction/deletion cannot leak stale facts into prompts; no duplicate facts from repeated ingestion; migration and recovery checks pass.

### 6. Qualify a release candidate on a phone

- Once tuning is finished, run the untouched held-out split and report pass/fail/incomplete separately. Keep zero unsafe writes as a hard requirement; do not equate an aggregate score with safety.
- Run the multi-turn corpus and real-device checklist: denied/revoked permissions, closed-app delivery, process death, reboot, timezone change, cancellation, widget/main-app concurrency and memory-pressure unload/reload.
- Distinguish OS force-stop from ordinary process death; document actual Android limitations instead of promising delivery in every lifecycle state.
- Measure cold/warm and sustained-use latency, thermal behavior and RAM with the current model. Confirm no INTERNET permission in the release artifact.

Exit: publish the exact tested candidate identity and remaining limitations. Broad acceptance requires completed reliability and device gates, not a short manual demonstration.

## Immediate work package

Do phase 1, then phase 2 as the first implementation package. This directly addresses the new product policy and the discovered model wait on otherwise deterministic replies. Follow with the day-only-call fix, prompt experiments, and targeted memory/persistence improvements. Keep changes separately reviewable and retain before/after evidence.

Defer voice, larger models, additional inference frameworks, vector search, neural summarization, background extraction and a wholesale interpreter rewrite until this baseline is reliable and measured.

## Evidence reviewed

- [Mem0/Hermes study](architecture-study-mem0-hermes.md)
- [Known gaps](known-gaps.md), [reliability status](reliability-status.md), [performance validation](performance-validation.md)
- [Request flow](../architecture/request-flow.md), [data model](../architecture/data-model.md), [LLM engine](../architecture/llm-engine.md)
- [Evaluation protocol](../../eval/README.md)
- Current source: `session.dart`, `rule_engine.dart`, `engine.dart`, `db.dart`, `repos.dart`, and native scheduling references. Existing graph traversal was used to locate relationships; conclusions above were checked against source and documentation.

The initial planning pass used source/document review and local-link checks. Subsequent implementation and automated evaluation are recorded below.


## Implementation checkpoint — 29 October 2026

Implemented in this checkout:
- Conversation-local first-request scope refusal, immediate similar-repeat allowance, reset on unrelated requests, and bypasses for core requests, pending time answers and arithmetic.
- Scope refusals skip plan, prose and mascot inference. Conservative deterministic classification leaves uncertain phrasing to existing interpretation.
- Conversational prose length cap with explicit-detail and persisted-request exceptions; execution receipts and lists retain their factual content.
- Validated deterministic confirmations reach the display callback before optional mood inference. The handle still waits for mood completion; this is a first-display improvement, not an end-to-end latency claim or asynchronous mood worker. _Superseded:_ the P3 package in the [acceptance report](architecture-acceptance-report.md) dispatches optional mood in the background (`_dispatchOptionalMood`), so the turn handle no longer awaits it.
- Day-only calls ask their time and retain the requested date through clarification.
- Planning prompt marks retrieved saved facts as reference data rather than instructions.

Automated verification: complete legacy and unified suites passed 503 tests, 2 skipped before the final scope similarity refinement; the final legacy suite also passed 503 tests with 2 skipped, and final targeted checks passed 78 tests. Rules-only development evaluation was executed and saved separately as `eval/results/rules-dev-2026-10-29.json`; its scorer reports 83 passes, 14 failures and 5 incomplete checks. This run predates the final scope/concision refinements. The historical baseline file was preserved. Frozen-corpus integrity validation passed. No held-out inputs were read for tuning.

Still outstanding: full multi-turn corpus runner, measured tuned-model baseline, prompt compression experiments, indexed memory deduplication, storage journal policy validation, comprehensive temporal expansion, and real-device qualification. No phone was connected and no local GGUF was found in the checked Downloads or /tmp locations. These changes do not complete all six phases or establish broad reliability acceptance.
