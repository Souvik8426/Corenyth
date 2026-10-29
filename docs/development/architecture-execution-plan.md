# Corenyth architecture execution plan

Planning date: 29 October 2026. Source reviewed: `abb3420` (`feat: add core scope policy and improve reply handling`). Status: **implementation in progress** (P0–P2 first batch started 29 October 2026). Qualification remains open. See [architecture-acceptance-report.md](architecture-acceptance-report.md).

This is the implementation companion to [architecture-next-steps.md](architecture-next-steps.md), based on [CORE_RULES.md](../../CORE_RULES.md) and the [Mem0/Hermes study](architecture-study-mem0-hermes.md). Historical results are in [reliability-status.md](reliability-status.md). New tasks below are proposals, not delivered features. The study is currently untracked and should be included when committing this documentation.

## 1. Outcome and fixed boundaries

Deliver an offline assistant that reliably saves and retrieves personal facts, handles supported tasks/reminders and their follow-ups, answers briefly, and finishes deterministic turns without waiting for optional inference. Every mutation continues through existing authorization, candidate validation, execution receipts and operation recovery.

Preserve FTS4, the allowlisted model, existing conversation history, notification delivery machinery, and the current interpreter modes. Do not introduce Mem0/Hermes as runtime dependencies. Their useful patterns are observation-time grounding, explicit memory updates and provenance, reference-data boundaries, and bounded context. Vector search, background fact extraction, new model families, voice and a general agent loop remain outside this delivery.

Capability wording must describe actual behavior. In particular, an Android scheduled notification is not automatically a wake-up alarm with ringing/snooze guarantees, and internal tasks are not external calendar synchronization. P0 must document the existing mapping and make unsupported requests truthful. Building a separate alarm-clock or calendar integration requires its own scope.

## 2. Verified starting point

| Area | Present | Remaining |
|---|---|---|
| Scope | Conservative `CorePolicy`, first refusal, lexical repeat comparison | Bypass turns do not advance/reset policy; state is session-instance local; keyword matching is incomplete |
| Concision | 360-character cap on selected model-chat branches | Coverage across response paths, Unicode-safe boundary handling, streaming/final consistency |
| Turn completion | Early callback for deterministic reply | Assistant-message persistence and `handle()` still wait for `_moodOnlyCall` |
| Mood | Per-message model provenance and stale-event checks | Independent optional-job ownership; controller currently closes acceptance at `endTurn()` |
| Dates | Captured turn clock; day-only call clarification | Restart/boundary coverage and observation-time metadata for relative facts |
| Prompt size | Existing `Prompt.candidates`, `budgeted`, native token checks and prefix reuse | Host parity, measured diagnostics, retained-context quality and compression experiments |
| Memory | Transactional dedupe/supersession, active-only FTS retrieval | Full active-row scans for dedupe/slots; date grounding; deletion/history leak tests |
| Evaluation | Frozen single corpus, scorer, native host path | 23 multi-turn scenarios not run; incomplete checks; exhaustive unexpected-write detection |
| Storage | Schema v9, operation journal, native readers | Connection/journal inventory and contention/recovery evidence |

The 83 pass / 14 fail / 5 incomplete rules-only checkpoint predates final refinements. It must be rerun before calling any later result a regression or improvement. Passing unit tests does not establish actual model accuracy or Android delivery.

## 3. Work order and dependencies

| Package | Depends on | Reviewable deliverable | Completion gate |
|---|---|---|---|
| P0 Contract and baseline | None | Capability matrix, immutable run identity, current rules baseline | Every core rule mapped to examples and checks |
| P1 Evaluation infrastructure | P0 | Multi-turn runner, complete state scorer, native parity | All 23 scenarios executed; scorer negative controls pass |
| P2 Scope and reply policy | P0, P1 scoring | Per-conversation policy transitions and output coverage | Zero inference on first refusal; all reset/isolation cases pass |
| P3 Foreground/background inference | P1 diagnostics | Durable fast replies and cancellable optional mood jobs | Slow/stale mood cannot block or corrupt foreground turn |
| P4 Temporal and fact grounding | P1; coordinate schema with P6 | Clarification/restart fixes and observation metadata | Exact timestamps; ambiguous inputs never write guessed dates |
| P5 Prompt efficiency | P1, P2, P3, P4 | Controlled prompt experiments and selected winner | No case-level correctness regression; measured device benefit |
| P6 Memory and storage | P1, P4 data contract | Indexed memory if justified; migrations; journal decision | Correction/deletion/migration/concurrency gates pass |
| P7 Release qualification | P0–P6 | Candidate report and phone evidence | All mandatory gates completed or release explicitly blocked |

Execution order: P0 → P1 → P2 → P3 → P4 → P6 → P5 → P7. Doing memory/context semantics before final prompt experiments avoids repeatedly invalidating the prompt baseline. Independent document and fixture preparation can proceed alongside implementation, but keep one migration owner and one session-lifecycle owner. Each package should be a separate reviewable commit or small commit series.

## 4. P0 — contract and reproducible baseline

**Files:** `CORE_RULES.md`, `eval/source_manifest.py`, `eval/README.md`, `docs/development/reliability-status.md`, `device-evaluation.md`.

1. Create a capability table with supported wording, resulting stored entity, permission requirements, truthful receipt, missing-information behavior and known unsupported variants. Cover reminder, alarm request, task, note, schedule, saved fact, cancellation, correction and detail request.
2. Inventory current interpreter and model settings. Record source content hash as well as Git revision, dirty state, corpus hashes, prompt fingerprint, backend revision, model SHA-256, context size, token caps, timezone, clock and scheduler mode.
3. Store each run in a new directory such as `eval/results/runs/<run-id>/`; never overwrite historical baselines. Generate the source manifest immediately before execution and reject stale manifests or mismatched corpus identities.
4. Run the frozen-corpus validator, current tests in both supported interpreters and current rules-only development corpus. Label unavailable model/device measurements as not run.
5. Preserve frozen expectations. If newer core rules conflict with an old expectation, add a separate policy-contract suite and a documented adjudication; do not silently rewrite or re-freeze the corpus.

**Acceptance:** a reader can reproduce the baseline from the recorded command/environment and distinguish deterministic, model-assisted and device results. Update outdated device-checklist expectations for first general-knowledge refusal and supported model catalog; keep historical reports clearly historical.

## 5. P1 — reliable evaluation before more tuning

**Files:** `test/reliability_corpus_test.dart`, `eval/score.py`, `eval/native_host.cpp`, `eval/validate.py`. Proposed additions: `test/support/eval_harness.dart`, `test/reliability_multi_corpus_test.dart`, scorer fixtures/tests under `eval/tests/`.

### Runner contract

- Extract fixture creation, state snapshots, source identity and engine selection into shared support. A scenario owns one disposable on-disk production-schema database; a single case owns a fresh database.
- Apply all setup fields, including reminder kind, history kind/time, preferences and environment. Unsupported fixture fields must fail setup explicitly, never be ignored.
- For each multi-turn entry, apply cumulative `advance_min`, then `restart_before`, chat selection and input. Restart closes sessions/database and reopens the same database; do not rebuild data from fixtures. One session per active chat, sharing app-global facts/tasks according to existing product semantics.
- Preserve stable fixture refs. Resolve `$last` to the previous turn's matching primary entity using typed execution receipts, not highest row id or an arbitrary pre-alert. Ambiguous references fail the harness.
- Implement `cancel: before_commit` through a deterministic barrier immediately before mutation, using a narrowly scoped test hook if necessary. Never use timing sleeps to approximate cancellation.
- Use a recording scheduler with configurable permission/error responses. Capture requested scheduling, cancellations and accepted/refused delivery requests separately from database state. This proves scheduler behavior, not physical notification delivery.
- Record per-turn before/after snapshots, receipts, clarification metadata, reply, route, call counts, timing and errors; record final scenario state. Include operations and relevant message/pending/mood state without treating ordinary conversation logging as a forbidden domain write.
- A scenario passes only when every turn and final-state assertion passes. Report turn and scenario counts independently. Missing, duplicate or unexpected case IDs invalidate the run.

### Scoring contract

Replace broad heuristics with an explicit state-delta model keyed by table/id. Detect inserts, deletes and field changes; compare the full delta against expected operations and their documented subordinate writes (for example linked task and configured pre-alerts). `forbid` applies across every acceptable alternative. An extra unrelated write fails even if the requested write succeeded.

Implement checks for pending fields/clearance, awaiting flags, exact dates, event details, supersession/deletion, disabled linked alerts, final-state counts and scheduler outcomes. Score clarification fields using structured diagnostics plus user-visible question checks, not punctuation alone. Evaluate every `also_ok` alternative fully; an incomplete alternative cannot erase a known forbidden operation.

Keep factual reply checks separate from style. `uses_memory` requires retrieval/prompt evidence plus response assessment; merely returning the right word is not proof of memory use. Broad groundedness/tone checks may need an explicit human rubric (0 = contradicted, 1 = partial, 2 = fully grounded). Unreviewed required rubrics remain incomplete. Synthetic evaluation may retain text; production diagnostics must not log private content.

Add scorer tests that deliberately introduce an extra task, wrong timestamp, missing deletion, active superseded fact, cross-chat draft leak, missing case, unknown field and wrong `$last`. Each must fail for the intended reason. Validate a passing fixture for each operation too.

### Native parity and observability

The host runner currently renders one prompt and uses output caps that differ from `LlamaChannelEngine` (production plan 140/reply 132; host generic path 120). Share or explicitly mirror production caps, grammar, candidate selection, tokenizer behavior, 2048-token context and sampler settings. Record any remaining backend differences. Fresh-process host calls cannot measure warm prefix reuse.

Instrument named timestamps: submit, route complete, commit complete, assistant reply persisted, first final confirmation callback, handle settled, optional mood queued/started/completed. Model calls record purpose, queue wait, input/output/reused tokens and cancellation outcome. Missing measurements are null/unavailable, never zero. Use operation IDs and metadata only in production.

**Acceptance:** all 23 frozen development scenarios produce results; no silently ignored directives; scorer self-tests pass; every remaining incomplete assertion is named with its missing evidence. Do not require the app to pass all scenarios before merging the harness—it must faithfully expose failures.

## 6. P2 — complete scope and concise-response behavior

**Files:** `lib/assistant/core_policy.dart`, `rule_engine.dart`, `session.dart`, `engine.dart`, `test/core_policy_test.dart`, `test/pa_routing_test.dart`.

### Scope state machine

Introduce a typed decision (`core`, `refuse`, `persistedOutside`, `uncertain`) with a reason. Evaluate a policy transition once for every newly submitted nonempty user turn, including arithmetic and pending answers. Replaying an operation does not advance it. Pending/core routing keeps precedence over outside classification.

Store `{chatId, lastOutsideTopic, lastAllowedTurnOrdinal}` in a conversation-owned in-memory policy store, injected into sessions. Recreating a session within the running app retains that conversation's state; another chat starts independently; process restart clears it deliberately. This matches an immediate conversational exception without permanently unlocking outside requests. If later durable persistence is desired, it needs a separate contract.

Transitions:

| Input | Decision | State afterwards |
|---|---|---|
| Core, pending answer, arithmetic or unrelated uncertain input | Existing route | Clear outside topic |
| Clearly outside, no immediately preceding matching topic | Exact refusal; zero plan/reply/mood calls | Save topic and ordinal |
| Immediately repeated same/similar outside request | Local chat answer only | Advance topic ordinal |
| Different outside topic | New refusal | Replace topic |
| Retry same operation | Replay stored result | No transition |

Use intent/phrase structure before generic keywords. “Explain task scheduling algorithms” is outside despite the word task; “remind me to explain code to Sam” is core. Preserve Unicode letters during normalization. Never compare two empty token sets as proof of topic similarity. Retain a conservative lexical threshold initially, tested against topic pairs; support explicit immediate persistence phrases such as “please answer anyway” only when a refused topic exists. Uncertain requests retain existing interpretation; document that a finite deterministic grammar cannot classify arbitrary language perfectly.

Persisted outside answers must be read-only even if generated output contains a tool plan. Existing authorization remains mandatory on every core request.

### Output handling

Centralize concise prose finishing and call it from every conversational model-response path. Preserve receipts, factual lists, dates and clarification fields. Keep the 360-character initial backstop, counting Unicode grapheme clusters and including any ellipsis in the limit; prefer a complete sentence. Explicit detail and immediate persisted outside turns bypass the ordinary cap, while native output tokens remain bounded.

Apply the same display limit to streaming previews so a long draft does not flash before truncation. Generated prefixes/personality lines must pass through the appropriate final policy without shortening factual receipts. Add a prompt instruction consistent with this contract.

**Tests:** both interpreters; first refusal with loaded model; repeated/rephrased/different topic; intervening calculator and pending answer; same-chat session reconstruction; chat switch; retry; process-reset semantics; empty topic; Unicode; core requests containing code/essay words; unauthorized tool output after an outside repeat; 20-result list; emoji and sentence truncation; explicit detail; streamed/final agreement.

**Acceptance:** all policy examples pass with exact model-call assertions and no unexpected writes. Unsupported classifier coverage is documented rather than described as universal.

## 7. P3 — durable foreground replies and independent optional mood

**Files:** `lib/assistant/session.dart`, `engine.dart`, `lib/mascot/mood_store.dart`, session UI callbacks, `android/app/src/main/kotlin/com/corenyth/assistant/LlamaBridge.kt`. Proposed small modules: inference coordinator and optional mood job owner.

Do not detach the existing `_moodOnlyCall` with an unawaited future: it reads mutable session fields/callbacks and `_complete` shares turn budget and cancellation ownership.

### Foreground completion order

1. Validate and commit the candidate through the existing executor/journal.
2. Compose the factual reply and persist its assistant message and final journal receipt before the final callback.
3. Make reply persistence idempotent by operation identity. Inspect the existing replay/crash window: a crash between message insertion and journal marking must not duplicate the assistant reply on retry. Prefer an existing shared transaction; if a message-operation key is necessary, include it in the coordinated schema migration.
4. Emit the final confirmation once; return the foreground result and restore input availability. Preserve existing speech semantics but measure optional speech separately from text-ready time.
5. Submit eligible optional mood work with immutable captured inputs, independent of mutable `_op`, `_moodSink`, `_budget` and `_turnNow`.

### Ownership and scheduling

An optional job captures conversation ID, operation ID, user-message row ID, turn observation time, model identity, bounded text/profile snapshot and a generation epoch. Queue at most one replaceable optional job per active conversation; discard queued older work when a new user turn arrives. Do not retain an unbounded background queue.

Use one inference coordinator at the shared native-context boundary, covering main chat, widget and optional inference. Foreground work has priority. Cancel running optional work by its request ID and await native termination before granting another request the context. Existing engine `cancel()` cancels all active IDs; add scoped handles or enforce single-owner cancellation so an old job cannot cancel a new foreground request. Never run a second generation merely because a cancellation deadline expired; mark the backend unavailable/recover it under exclusive ownership if cancellation fails.

Optional work must not load an unloaded model or prevent idle unload. New turn, chat disposal, model unload and app shutdown invalidate its epoch. Failure leaves unknown/calm, never a guessed mood. Background mood diagnostics are separate from the settled foreground turn's call counts.

### UI and persistence

Persist valid readings only against the captured existing user row and operation. Check epoch and row existence immediately before persistence/emission; deleted chats must not be recreated. Use an independent late-mood event channel rather than a callback cleared in `handle().whenComplete()`.

`MoodController.endTurn()` currently rejects subsequent events. Split text completion from optional-mood acceptance: a completed current turn may accept its own valid optional reading until a newer turn/cancel/dispose closes the window. Historical adoption may update that row only; it must never change the live mascot of a newer turn. Keep first-valid-reading wins and model provenance.

**Tests:** controllable never-finishing/slow model; reply and journal already persisted while mood is blocked; second turn accepted; late tokens after cancellation; cancel failure; chat switch/delete; unload; two surfaces; replay after crash at each persistence boundary; mood save failure; refusal/mechanical route queues nothing; no duplicate final callback.

**Acceptance:** foreground result settles without awaiting mood; no stale updates or cross-request cancellation; existing operation/mood tests pass. Device target remains p95 under 500 ms for supported deterministic text confirmation; measure rather than infer it from host tests.

## 8. P4 — temporal semantics and observation grounding

**Files:** `lib/assistant/temporal.dart`, `rule_engine.dart`, `session.dart`, pending repositories and temporal tests; memory metadata coordinated with P6.

First create a supported-expression table from current parser behavior. Keep tested weekday/default-time semantics; do not silently change “Sunday” globally. For each added form, specify same-day/past-time behavior and whether the result is a task due date, event time or reminder trigger. Day-only calls/events ask for time; ordinary date-only tasks retain their documented default if that is the established contract.

Use one captured clock per turn. A pending draft keeps resolved calendar day, explicitly supplied components, originating timezone/offset and clarification kind. A later bare time combines with that saved day; a relative answer such as “in ten minutes” is evaluated at the answer turn's clock. Restart must preserve these distinctions. If the saved date has become past or a timezone change creates ambiguity, ask instead of rolling it forward silently.

For explicit date-bearing memories, distinguish `observedAtUtc` from the fact's event date. Store observation zone/offset when available and a normalized date/instant only when deterministic resolution succeeds. Preserve original wording and provenance. An old row's creation timestamp is not proof of the timezone or relative date originally intended; leave unknown metadata null during backfill.

Calendar-day arithmetic uses calendar boundaries; elapsed minutes/hours use durations. Test local midnight, end of month/year, leap day, Sunday on Sunday, passed time, restart after midnight and timezone changes. Use a timezone-capable deterministic fixture for DST tests; if named-zone parsing is unsupported, declare that boundary and test truthful refusal/clarification rather than guessing.

**Acceptance:** exact stored timestamps and preserved draft fields in both interpreters; no creation before required clarification; correction/deletion of date-bearing facts works; ambiguous relative facts do not become timeless assertions.

## 9. P6 — memory indexing, migration and SQLite policy

**Files:** `lib/data/db.dart`, `repos.dart`, memory retrieval tests, migration tests, native widget/headless database open sites discovered during connection inventory.

### Benchmark and indexed representation

Measure ingest/correction/retrieval at 100, 1,000 and 10,000 synthetic active facts, including duplicate-heavy input. Record query plans and rows scanned. Retain current behavior if indexing has no material benefit at intended volumes; document the decision. Index implementation is required if active-row scans demonstrably dominate write latency or exceed the target workload budget established in P0.

Proposed next schema is v10 **only if v9 is still current when implementing**. Add nullable `content_hash`, `subject_key`, `attribute_key`, `observed_at_utc`, observation timezone/offset and resolved fact-date metadata as justified by P4. Define hash normalization version explicitly: preserve current lowercasing/terminal-punctuation/whitespace rules initially; do not reorder words or remove negation. Use SHA-256 with a non-unique `(status, content_hash)` index, then compare normalized text to handle collisions. Index `(status, subject_key, attribute_key)` for recognized slots. Do not merge unrelated subjects or force every note into a slot.

Backfill deterministically in the migration transaction, without inference. Preserve IDs, source, operation IDs, supersession links and timestamps; do not invent observation metadata. Existing duplicate rows need not be destroyed merely to install a non-unique index. New ingestion checks candidates inside the existing transaction; concurrent duplicate writes converge under SQLite write serialization. Replayed operations must not repeatedly bump importance.

When correcting a recognized fact, atomically insert the replacement, supersede the prior active slot value and update FTS visibility. Deletion/correction must also prevent old conversation text from reintroducing that fact as current personal context. Add a context-construction test across chats, restart and long history. User-visible chat history remains intact; retrieval provenance/selection controls what becomes current memory.

### Connection and journal decision

Inventory every SQLite open path, its read/write role, migrations, foreign-key setting, journal mode, synchronization and busy timeout. Query effective pragmas on Android; FFI host defaults are not Android evidence.

Benchmark current mode against WAL in a disposable device profile with main-app writes, widget reads and headless scheduling. Adopt WAL only with compatible open paths and measurable benefit; otherwise retain the existing mode and record why. If adopted: choose FULL durability initially, a bounded busy timeout, default/explicit auto-checkpoint policy and passive checkpoints at suitable idle boundaries. Measure WAL growth with a long reader; do not force truncation on every turn. Retry only idempotent operations after contention, never duplicate executor work.

**Tests:** fresh schema, each supported upgrade path, rollback after interrupted migration, FTS4 availability, native readers, duplicate ingestion, hash collision simulation, Unicode/negation preservation, independent subjects, stale fact exclusion, foreign keys, long reader and competing writer, process death after commit. Upgrades preserve all user data; rollback testing uses database copies, not destructive production downgrades.

**Acceptance:** migrations and behavior tests pass; no stale fact reappears in any prompt path; benchmark/journal decision recorded. If no schema change is justified, explicitly close the indexing task with evidence rather than leaving a speculative migration open.

## 10. P5 — controlled prompt and context experiments

**Files:** `lib/assistant/engine.dart`, context assembly in `session.dart`, `android/app/src/main/cpp/llama_jni.cpp`, native evaluation tooling. Preserve the vendor llama.cpp tree unless a demonstrated defect requires a separate change.

The app already selects candidate renders and checks actual native token fit. Extend and measure that mechanism rather than building a parallel tokenizer estimate.

1. Freeze a baseline after semantic fixes and native-host parity. Keep model, sampler, context and dataset fixed.
2. Experiment separately with redundant instruction removal, compact tool/intent descriptions, and moving dynamic personal data out of stable prefix positions. Compare one change at a time; bump/fingerprint the prompt contract.
3. Preserve current input, required pending state and resolved target evidence. Select relevant tasks with database queries, never arbitrary first-ten clipping; ambiguous missing targets must clarify. Drop oldest history, then optional facts according to measured relevance. Keep response-token reserve and grammar headroom.
4. If essential input still cannot fit, return an explicit bounded-input error and perform no speculative action. Never silently truncate user intent.
5. Apply reference-only framing and ChatML neutralization across both planning and reply context, including old assistant messages. Stored instruction-like notes are data, not authority. Test deleted/superseded facts and malicious-looking literal note contents.
6. Run development single/multi and policy/security regressions for each variant. Record case-level gains/losses, prompt tokens, retained evidence, cache reuse and inference calls. Reject a smaller prompt if it loses correctness.
7. Measure the selected variant on the phone for cold, warm and sustained 20-turn sessions. A warm cache gain must not be presented as cold-load improvement. Avoid optional mood jobs contaminating the benchmark; report enabled/disabled runs explicitly.

**Acceptance:** no case-level regression on mandatory correctness/safety checks; required facts survive context budgeting; actual cold/warm measurements support any claimed improvement. If no variant wins, retain the baseline and publish the experiment result.

## 11. P7 — release qualification and stopping rules

Create `docs/development/architecture-acceptance-report.md` during execution, linking immutable results and marking each gate passed, failed, incomplete or not run.

| Gate | Required evidence |
|---|---|
| Build and tests | Both interpreter suites; no new analyzer warnings/errors; skips individually explained |
| Evaluation integrity | Frozen manifest valid; exact expected case coverage; scorer negative controls pass |
| Core policy | All contract tests pass; first outside refusal has zero model calls |
| State safety | Zero unauthorized, wrong-target or duplicate writes; cancellation/retry gates pass |
| Development behavior | All mandatory supported-contract single/multi expectations pass; every residual failure adjudicated explicitly |
| Actual model | Allowlisted checksum and production settings; complete model-assisted development run |
| Held-out | Candidate frozen before running; pass/fail/incomplete reported separately; no tuning on exposed inputs |
| Storage | Supported migrations, correction/deletion and crash/reader concurrency pass |
| Phone lifecycle | Delivery, permissions, reboot, process death, timezone change, widget coexistence, unload/reload |
| Performance | Matched cold/warm/sustained runs; deterministic p95 target; memory/temperature and failures reported |
| Offline artifact | Release APK identity and merged-manifest absence of INTERNET permission |

Use at least 30 warm samples per representative route and 10 cold samples; report counts and raw metadata because cold p95 is unstable with small samples. Repeat after sustained use. Record device, Android version, model hash, thermal/battery state and installed APK checksum. Phone delivery tests use the real clock; corpus tests use the injected clock.

Distinguish Android force-stop from ordinary process death. Verify denied/revoked notification and exact-alarm permissions, permission recovery, edit/cancel delivery, reboot restoration and truthful saved-versus-scheduled receipts. Operate on clearly named disposable test data/profile, never clear the user's main database.

For broad completion, require all mandatory gates, not just a percentage score. A held-out unsafe write blocks release. A non-safety failure requires an explicit narrower supported contract or a new development cycle; do not announce complete language reliability. If held-out evidence drives another cycle, mark that split exposed and obtain a new untouched set for subsequent generalization claims.

If the model or phone is unavailable, finish all host-verifiable packages and prepare runnable scripts/fixtures; mark model/device gates not run and the release unqualified. Do not replace those results with mocked engines or invented performance estimates.

## 12. First implementation batch and ongoing tracking

Start with three commits:

1. **`test: make evaluation runs reproducible and validate scorer coverage`** — P0 identity/capability matrix and P1 scorer negative controls.
2. **`test: execute the frozen multi-turn reliability corpus`** — shared fixture runner, restart/chat/cancellation/scheduler semantics, complete results with honest failures.
3. **`fix: reset scope policy on every conversation turn`** — P2 state transitions, read-only persisted answers and concise-output coverage.

Then implement P3 as its own lifecycle change before memory/prompt optimization. Add a failing regression from each reproduced development defect before the fix. Run targeted tests per change, both full interpreter suites at package boundaries and model development evaluation when prompts/interpretation change. Run held-out only at candidate freeze.

For every package record: files changed, tests/commands, source identity, outcomes, remaining gaps and the next dependency. Update request-flow, LLM-engine and data-model docs alongside their respective code changes. Do not mark a package done merely because its code exists; its acceptance evidence is part of the deliverable.
