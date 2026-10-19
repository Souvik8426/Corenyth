# Implementation outcome — acceptance not achieved

Specific P0–P4 software repairs are implemented. P5 found a substantial held-out generalization gap; this plan is not complete. See [verification report](reliability-workflow/P5-report.md) and `reliability-workflow/state.json`. The candidate is not installed on the phone. The original proposed plan and self-answered grill review follow unchanged.

# Corenyth assistant reliability repair plan

Date: 19 October 2026
Status: implementation authorized; P0–P2 accepted; P3 in progress with agy Gemini 3.8 Flash (High), high effort; P4/P5 pending
Baseline inspected: c1d1ada plus current working tree
Method: Hermes Brain `grill-me`, with questions answered by the planner at the user's explicit request. Answers inferred beyond confirmed requirements are marked **proposed**. This is a decision record for review, not new user approval.

## 1. Outcome and existing commitments

Corenyth must understand ordinary conversational requests, act on the intended commitment, remember relevant context across chats, and follow through accurately on the phone. A fluent sentence or a passing mocked test is insufficient.

Preserve the confirmed contract in `docs/expectation-gap-report.md`:
- Fully local operation; Qwen interprets and converses; application code validates and executes. No product INTERNET permission.
- Configured preparation nudges and independently controlled outcome follow-ups.
- Save a meeting reminder before asking optional subject/end details; default outcome check is start + one hour when enabled.
- Completion cancels future linked alerts; discuss outcomes without repeating an answer already supplied.
- One evening review at DND minus 30 minutes; default DND 22:00–07:00. Ignored tasks remain in later reviews without invented deadlines.
- Context is global across display chats. Ambiguous people/tasks require clarification.
- Check-ins belong in both notifications and main chat; restart/reboot must not duplicate them.

## 2. What the evidence establishes

### Screenshot

User: “Can u remind me i have a meeting within 10 mins”. The app asks when, includes “within 10 mins” in the title, and prints a long supported-date list. The banner says the default 0.6B model is being used after a selection failure.

This establishes an unacceptable visible result. It does **not** establish which model generated this turn, why selection failed, whether it was an out-of-memory event, or which checkout produced the installed APK.

### Current source

1. `rule_engine.dart::_inRe` accepts `in` plus a duration, including `mins`, but not `within`. Both semantic plans and fallback commands ultimately rely on this temporal parser. A correct model extraction alone cannot bypass the limitation.
2. `session.dart::_create` asks for clarification when the extracted time cannot be resolved. `ClarifyDraft.prompt` appends the entire supported-date help text. Parser limitation becomes “you did not tell me when”.
3. `_route` chains early handlers, lead overrides, complaints, follow-through heuristics, semantic planning, rules, and a final rule plan. A successful heuristic can bypass model interpretation. Responsibility for meaning is spread across routes.
4. `semantic.dart` has no structured intents for progress, event outcomes, optional event details, or multiple commitments. Those rely on other handlers. The grammar permits combinations that the semantic validator subsequently rejects.
5. `_semantic` and `_converse` both call `buildPersonalContext(..., const [])`. Persistent memories are not automatically retrieved into these principal prompt paths. Explicit recall uses `search_memory`; storage working does not prove conversational memory works.
6. Planning shows up to ten pending tasks; relevant older tasks need deliberate retrieval, not merely a larger prompt. Related chat retrieval is bounded separately.
7. `test/screenshot_replies_test.dart` uses `ScriptedEngine`; many behavioral tests use stand-in engines and repositories. They test responses to supplied model outputs, not Qwen's actual understanding. Existing device docs explicitly leave accuracy unmeasured.
8. Model load fallback is implemented, but a loaded-model label is not proof the model handled a particular turn. The screenshot needs build and turn-level evidence to distinguish load, interpretation, rejection, and fallback problems.

This document describes the repair; execution evidence is tracked in `docs/plans/reliability-workflow/`. Source inspection is not an end-to-end reproduction. Prior SQLite smoke checks do not validate model recall, phone alarms, or conversation quality.

## 3. Grill-me: visible questions and answers

### Round 1 — product boundary

**Q1 — What is success: better wording or a reliable assistant?**
Recommendation and answer: reliable capture → correct saved state → truthful confirmation → delivered reminder → contextual follow-through. Wording matters after the action is correct. This follows the confirmed requirements.

**Q2 — May cloud intelligence rescue a weak local model?**
Recommendation and answer: no. Fully local remains binding. Benchmark the supported local models; disclose degraded operation. Adding Mem0 cloud would violate this contract.

**Q3 — Should the screenshot request cause another question?**
Recommendation and proposed answer: schedule the meeting reminder ten minutes from message submission and explicitly confirm that interpretation. In this casual request, treat “within 10 mins” as the requested alert offset. Preserve the distinction for actual deadline statements: “finish within ten minutes” is not automatically an event start; “sometime within the next hour” may need one targeted question. Do not normalize every `within` to `in` globally.

**Q4 — Can we declare success when tests pass?**
Recommendation and answer: only when the tests include the real model and physical-device workflow. Existing unit tests remain necessary; they are not the product acceptance gate.

### Round 2 — architecture, dependent on Round 1

**Q5 — Should we patch a regex, rewrite everything, or consolidate interpretation?**
Recommendation and proposed answer: consolidate interpretation incrementally around a shared turn contract. Retain repositories, migrations, alarm reconciliation, and native inference. Fix the reported behavior as the first complete slice, then remove duplicate interpretation paths as their replacements pass parity checks. A regex-only patch would leave the systemic problem.

**Q6 — Who decides what the request means?**
Recommendation and proposed answer: Qwen supplies structured intent and evidence spans for general language. A narrow deterministic path handles fully recognized, unambiguous commands. Both produce the same candidate plan and use the same validator/executor. Incomplete rule recognition must yield an explicit unresolved state, not silently steal the request. Do not accept the model's self-reported confidence as permission to write.

**Q7 — How should time be represented?**
Recommendation and proposed answer: a typed temporal specification retaining the original span, relation, amount/unit or calendar fields, and role (event start, reminder time, deadline, end, recurrence). Resolve once against one captured submission time and timezone. Model normalization must be grounded in the original words; the model cannot invent an absolute timestamp.

**Q8 — What should happen when model interpretation fails?**
Recommendation and proposed answer: a validated deterministic interpretation can still execute; otherwise ask one short question about the unresolved field. Record whether the failure was model load, output structure, unsupported meaning, conflicting evidence, or execution. Never equate parser failure with absent user information.

**Q9 — Is installing Mem0 the memory fix?**
Recommendation and answer: no evidence justifies that dependency. First connect the existing local store to retrieval for planning and conversation, prove recall, and support corrected/deleted facts. Consider an offline retrieval component only if a measured benchmark demonstrates a remaining need.

### Round 3 — failure behavior, dependent on Round 2

**Q10 — What prevents believable lies about actions?**
Recommendation and proposed answer: execution returns a typed receipt with committed task/reminder identity, resolved time, and scheduling status. Render confirmation from that receipt. A conversational model may add optional wording but cannot change receipt facts. Distinguish “saved, notification permission required” from “reminder scheduled”; scheduling is still not proof of delivery.

**Q11 — What if context points to two people or an old task?**
Recommendation and answer: retrieve candidates from current database state before prompt truncation; exact task references and the pending interaction outrank approximate matches. Ask which candidate if ambiguous. Persist typed pending interactions with entity identity and known fields so cross-chat replies/restarts preserve meaning. Retrieved memories remain data, never execution instructions.

**Q12 — What if the request is cancelled, retried, or interrupted?**
Recommendation and proposed answer: one persisted operation identity per submitted action, re-used only for a retry of that action. Commit state and scheduling intent transactionally; reconcile delivery separately. Cancelling before commit writes no action; after commit, preserve and report the actual result. A newly sent similar reminder is not automatically treated as a retry. Test crash boundaries rather than assuming exactly-once delivery.

**Q13 — How do we prevent personality fixes from damaging correctness?**
Recommendation and proposed answer: keep action receipts deterministic; evaluate conversational replies separately for relevance, repetition, appropriate tone, and useful next steps. Replace the blanket time-format dump with a field-specific question. Complaint handling re-examines the failed turn and actual state instead of merely paraphrasing it or repeating a write.

### Round 4 — delivery and release, dependent on Round 3

**Q14 — Is 0.6B sufficient; should 1.7B become the default?**
Recommendation and proposed answer: neither assertion is justified yet. Run both supported models through the same frozen corpus and measure end-to-end success, native failures, memory, and latency on the reference phone. The model/prompt/schema combination must earn release. Do not make a larger model the default from parameter count alone.

**Q15 — What if no model meets the bar?**
Recommendation and proposed answer: do not label the assistant fixed. Use failure breakdowns to simplify schema/prompts, improve relevant context, or evaluate another offline candidate as a separate measured experiment. Keep dependable deterministic commands available and make limits visible. No guarantee that a small local model can satisfy every conversational request.

**Q16 — How do we avoid another broad patch with a passing test count?**
Recommendation and proposed answer: deliver gated vertical slices, keep a held-out phrasing set, record results per model and route, and require real-device evidence before release. Implementation order below is sequential where contracts depend on earlier decisions. Roll back a failing interpreter without rolling back user data.

All planning branches have recommendations. Device facts and model suitability remain evidence gaps, not questions being pushed back to the user.

## 4. Target flow and contracts

`TurnInput → ContextBundle → CandidatePlan → ValidatedAction or Clarification → ExecutionReceipt → Reply`

- **TurnInput:** turn/operation identity, raw text, captured time/timezone, chat identity, cancellation state.
- **ContextBundle:** relevant current tasks, typed pending interaction, related global messages, profile and relevant durable memories; provenance and bounded token allocation for each. Mandatory current request and pending fields survive trimming.
- **CandidatePlan:** supported intent, entity evidence, temporal specification, relevant preference overrides, unresolved fields, and interpreter source. The grammar must reflect intent-specific fields. Introduce progress/outcome/detail intents in a second contract version after the simple action slice is stable.
- **ValidatedAction:** resolved entities and time, explicit authorization evidence, conflict checks and existing tool mapping. No persistent write while still proposing or clarifying.
- **ExecutionReceipt:** committed identities, resulting state, alarm accepted/pending/failed, and recoverable error. Build on existing durable sync mechanisms.
- **Reply:** factual action confirmation plus optional grounded conversational text, or one targeted clarification. No unsupported action claims.

One coordinator chooses routes. Domain handlers can remain separate implementation units; they must return explicit handled/not-handled/needs-clarification outcomes through the shared contract. Remove superseded special cases only after their regression suite passes.

## 5. Ordered implementation work packages

### P0 — establish a reproducible baseline (blocks acceptance claims)

Scope: diagnostic path in session/engine/model services; `docs/device-evaluation.md`; a local evaluation fixture directory.

Record installed APK identity versus checkout, phone/Android/RAM, selected and active model/checksum, load failure code, prompt/grammar version, and actual route for each turn. Capture the exact screenshot request with fixed-time tests, then in a disposable phone test profile/chat. Preserve user data. Verify toolchain and build reproducibility; identify missing setup explicitly.

Create a frozen evaluation corpus before changing prompts: at least 120 single-turn examples across scheduling, updates, lists, progress, memory, ambiguity, negation and general chat; at least 20 multi-turn scenarios. Reserve at least 30 single-turn cases as held-out variants. Include the user's historical failure cases. Keep expected state changes separate from preferred wording.

Gate: baseline report exists with failures classified and unrun checks marked unrun. No invented baseline percentages.

### P1 — repair temporal understanding as one complete slice (depends P0)

Scope: new focused temporal module; `rule_engine.dart`, `semantic.dart`, `session.dart`; parser and session regression tests.

Introduce the shared temporal type and capture time once per submitted turn. Handle natural duration forms, short units, word numbers and fillers without corrupting titles. Distinguish “in”, event-relative “within”, deadline “within/by”, “before”, recurrence and event end. Preserve existing supported calendar forms and explicit disclosed defaults. Detect contradictions rather than picking the first timestamp.

Route both model extraction and deterministic fallback through the same resolver. Preserve usable fields when asking for one missing or conflicting value. Do not add a second independent date parser.

Gate: the exact screenshot request creates one meeting reminder at submission + 10 minutes, title without temporal filler, and a concise confirmation; works with valid Qwen extraction and with Qwen unavailable. No broad date-help message. Boundary/negation/conflict tests pass. Optional meeting details never block creation.

### P2 — unify interpretation and execution boundaries (depends P1)

Scope: coordinator/plan/validation/receipt modules extracted from `session.dart`, semantic grammar and prompts, existing tools/repositories where receipts and operation identity require them.

Implement the contracts above for create/update/complete/list/recall first. Inventory existing early/follow-through handlers and migrate each with explicit priority and parity tests. Add progress/outcome/detail support next. Bound model calls; never retry identical greedy output without changing the request or evidence. Measure any repair attempt before enabling it.

Keep current scheduling semantics and cancellation recovery. Add an additive, data-preserving migration only if durable operation identity or typed pending records require one. Test old pending records and existing task/widget consumers.

Gate: each accepted action has one route, validated evidence and one receipt; ambiguous/negated/hypothetical input produces no unintended writes. Retry/crash tests do not duplicate tasks or alarm intents. Existing follow-through acceptance cases pass.

### P3 — make global context and memory useful (depends P2 context contract)

Scope: context builder, memory/task/conversation repositories and planner/reply prompt construction.

Retrieve relevant tasks before applying caps; include explicitly referenced older items. Inject relevant durable memories into planning and conversation rather than passing an empty list. Keep mutable task facts sourced from SQLite. Store provenance and define correction behavior: an explicit new preference supersedes its prior value, ambiguous contradictions ask, deleted memories disappear from future context. Exclude temporary plans from durable personal facts.

Persist the interaction type and target for clarification and outcome follow-ups. Cross-chat replies should continue the right open interaction; competing open questions require a short disambiguation.

Gate: cross-chat recall, corrected preference, deletion, older-task reference, competing people and restart tests pass with the real retrieval path. Prompt budget tests retain the current request and required pending fields. A storage-only test cannot close this work package.

### P4 — truthful, concise responses and visible model health (depends P2; integrate P3)

Scope: reply policy, clarification rendering, model status view and service state.

Use receipt-driven confirmations and field-specific questions. Preserve the requested tone without parroting or unsolicited task creation. Complaints inspect the original intent and receipt, acknowledge the actual mistake, and request correction only when necessary. Separate selected model, resident model, and the route used for the last turn. Show an actionable failure reason in model details; routine chat remains plain language.

Gate: narrow-screen checks plus response rubric on real outputs. The loaded-model banner cannot imply that every answer used Qwen. Load failure, parser rejection and notification failure yield distinct, accurate messages.

### P5 — qualify the model and release on the phone (depends P1–P4)

Run the frozen corpus through actual native inference with the same prompt/grammar/settings as the app. Run 0.6B and 1.7B separately when the phone supports them, and run a forced-unavailable model mode. Report assisted end-to-end success and model-only plan accuracy separately so fallback does not conceal model weaknesses.

Run physical-device scenarios: exact screenshot request; reminder fires screen-off; optional follow-up; completion cancels it; cross-chat memory; process restart; reboot recovery; permission denial/re-enable; model-load failure; cancellation and immediate new turn. Use a release/profile build and disposable test data.

Gate: acceptance thresholds below are met, evidence is attached, build identity is recorded, and known remaining gaps are explicit. A build or unit-test pass alone cannot close P5.

## 6. Acceptance matrix and release gates

For fixed-time examples use 19 October 2026, 07:41 Asia/Kolkata. Device tests use their actual captured submission time.

| Request/scenario | Required result |
|---|---|
| Screenshot request, “meeting within 10 mins” | One reminder at 07:51; clean meeting title; concise confirmation; no question asking for the supplied time |
| “Remind me in ten minutes to call Mum” / “after 10 min” | Same duration interpretation; no dependence on word order |
| “Meeting in 10 minutes, remind me 5 minutes before” | Event at 07:51, requested alert at 07:46; preserve distinction; no invented extra alert policy |
| “Finish this within 10 minutes” | Recognize deadline meaning; do not silently create a meeting or infer notification authorization |
| “Maybe I should meet him within an hour” | No reminder write; uncertainty remains conversational |
| “Don't remind me about the meeting” | No new reminder; clarify cancellation target if competing reminders exist |
| “Meeting in 10 minutes at 9” | Ask about the conflicting times; no first-match scheduling |
| “Remind me about the meeting” → “in ten minutes” after restart | One complete reminder; preserved subject and pending interaction |
| “Aditya hasn't replied” with two relevant Adityas | Ask which one; no arbitrary completion/new task |
| “Done with the meeting; no useful outcome” | Complete correct task; cancel future alerts; do not ask an already answered outcome question |
| “I prefer short answers” → new chat | Relevant preference affects the reply; correction and deletion take effect |
| Old relevant task beyond first ten | Retrieve and resolve it or clarify; never pretend it does not exist |
| Notification permission denied | Saved state and unscheduled status are accurately distinguished |
| Model unload/failure | Correct constrained fallback or one useful question; accurate model state |

Proposed release thresholds (targets, not measured claims):
- 100% of the screenshot and existing explicit user-requirement scenarios pass.
- Zero unintended mutations, wrong-entity completions, duplicate writes on retry, or false successful-action claims across the safety suite. Any such failure blocks release.
- At least 95% correct end-to-end outcomes on the frozen single-turn set, reported per category and route; no category below 90%. Multi-turn critical workflows all pass. Judge expected action/clarification, not exact wording.
- At least 90% of reviewed conversational outputs are relevant, grounded, concise, non-repetitive and tone-appropriate; report individual rubric dimensions. Human review should include the user's sample failures.
- Proposed reference-phone targets: deterministic confirmation p95 under 500 ms; warm model action confirmation p95 under 5 seconds; warm conversational completion p95 under 8 seconds. Report cold-load latency separately. If infeasible, make a documented product tradeoff rather than silently relaxing the target.
- Repeat critical workflows at least ten times including cold/warm runs; report failures, p50/p95 latency, peak memory, thermal conditions and load stability. Passing a small sample is evidence, not a universal reliability guarantee.
- Run analyzer, relevant/full automated suite, migration checks, Android build, offline-permission check and the device checklist on the same release candidate.

## 7. Diagnostics, rollout, and rollback

Production diagnostics contain turn ID, build/model/prompt versions, route, reason codes, token counts, timing and action status, without raw personal content. An opt-in local evaluation mode can retain synthetic inputs/model plans for diagnosis. Do not log personal prompts by default.

Introduce the coordinator behind an internal feature switch. Compare old and new interpretations read-only on synthetic fixtures; only one executor can write. Roll out the screenshot slice first, then full routing, then context/reply improvements. Preserve the old path until parity and device gates pass. New database changes must be additive with compatibility tested; do not promise binary rollback across an incompatible schema. Never clear the user's database as a troubleshooting shortcut.

## 8. Remaining evidence gaps and excluded work

Unresolved facts: installed build identity, exact model selection failure, actual per-turn model output, phone performance, and alarm delivery. Implementation begins with obtaining these facts; no additional product interview is needed to write the code.

The “within” convention, new contracts, evaluation thresholds and latency targets above are proposed planner decisions for the user to review. Existing confirmed product requirements take precedence.

Excluded from this repair: cloud services, Mem0 adoption without measured need, a wholesale UI redesign, voice implementation, autonomous contact with other people, and an immediate model replacement. Multiple commitments must retain the existing safe refusal until a separately validated atomic/split plan is implemented; do not silently execute a subset.

Completion means P5 evidence supports the stated product behavior. Until then report precisely which stage passed and what remains unverified. No promise that this plan alone guarantees model quality.
