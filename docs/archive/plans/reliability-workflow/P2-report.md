# P2 report: unify interpretation and execution boundaries

**Status: completed at software level; real-device execution deferred to P5.**
Baseline: `c1d1ada` plus accepted P0 and P1 working-tree changes. No commits, stashes, resets, cloud dependencies, or unpermitted file modifications were made. The evaluation corpus freeze was validated and held-out text was not read.

---

## 1. Scope & Architectural Summary

Stage P2 establishes a unified interpretation and execution boundary for the Corenyth assistant:
1. **Durable turn identity & journal:** Added SQLite schema migration v7 introducing the `operations` table (`op_id`, `chat_id`, `text_hash`, `status`, `action`, `receipt`, `created_at`, `updated_at`) and stamped operation IDs on `tasks` and `reminders`.
2. **Single-writer execution boundary:** Only `ToolExecutor` executes state changes (`create`, `edit`, `delete`, `complete`, `cancel`, `report`). `AssistantSession` coordinates and validates candidate plans without directly mutating database state.
3. **Structured contracts:** Extracted `CandidatePlan`, `Validation`, `ExecutionReceipt`, `TurnRecord`, `RouteId`, and `Interpreter` into `lib/assistant/turn_contract.dart`.
4. **Authorization gating:** Introduced `lib/assistant/authorization.dart` with `readAuthorization` distinguishing polite requests (`Authorization.request`) from informational questions (`Authorization.question`), hypothetical proposals (`Authorization.hypothetical`), and negations (`Authorization.negated`).
5. **Coordinator route table:** Unified 14 priority-ordered routes in `RouteId`, keeping the legacy route chain accessible via build-time/runtime interpreter switch (`--dart-define=CORENYTH_INTERPRETER=unified|legacy`).
6. **Crash recovery & idempotent replay:** Repaired startup stale operation reconciliation in `OperationJournal.recoverStale`, preserving validated actions and database-committed reminder times across process death, restarts, and time advances.

---

## 2. Route Inventory & Priority Order

In `RouteId` (`lib/assistant/turn_contract.dart`), every turn is resolved by exactly one route in strict priority order:

| Index | RouteId | Description & Trigger | Action Family | Migration & Parity Status |
|---|---|---|---|---|
| 0 | `explicitMemory` | "remember that …" explicit memo directive | `report` | Settled first; saves memory effect and acknowledges |
| 1 | `pendingPick` | Chat has an open target disambiguation ("#2", task name) | `change` / `report` | Consumes persistent/in-memory target pick |
| 2 | `calculator` | Pure arithmetic expressions ("2 + 2") | `reply` | Handled deterministically without model |
| 3 | `pendingAnswer` | Answer to open time question ("at 5pm", "cancel") | `create` / `change` | Consumes persistent `ClarifyDraft` |
| 4 | `complaint` | User expresses frustration/complaint | `reply` | Re-answers previous message, never mutates state |
| 5 | `dailySchedule` | "remind me daily at … until …" | `create` | Creates recurring daily task with alerts |
| 6 | `eventDetails` | Meeting details ("ends at …", "subject is …") | `report` | Updates event metadata and follow-up alerts |
| 7 | `eventDone` | "The meeting is over" | `change` | Marks event complete |
| 8 | `outcome` | Meeting/task outcome answer | `report` | Records outcome and clears open review prompt |
| 9 | `progress` | Progress update on existing task | `report` | Records progress discussion |
| 10 | `briefing` | "Brief me" / "what does my day look like" | `read` | Formats upcoming schedule |
| 11 | `negatedCancel` | Negated reminder request ("don't remind me …") | `read` / `reply` | Unified only: asks which to cancel; never creates or silently deletes |
| 12 | `semantic` | Local SLM plan (plan-v2 grammar/prompt) | dynamic | Bounded inference; validated before execution |
| 13 | `rules` | Deterministic rule matches | dynamic | Rule engine matches for standard task/reminder patterns |
| 14 | `rulePlan` | Fallback read-only plan | `reply` | Default conversational response when no route handled |
| - | `retryReplay` | Retried turn with existing final receipt | `replay` | Replays identical reply without writing |
| - | `retryRecover` | Retried turn recovering journaled action | `recovery` | Finishes executing journaled action; skips committed rows |

Dual-interpreter parity and divergence are measured without model calls via `InterpreterComparison(legacy, unified)`.

---

## 3. Production Wiring, Recovery, & Receipt Semantics

### Production Wiring (`AppServices`)
- In `lib/services/app_services.dart`, `AppServices.newSession` passes `operations: OperationJournal(db)` to every `AssistantSession` instance.
- At startup, `AppServices` invokes `OperationJournal.recoverStale(olderThan: const Duration(minutes: 2))` to reconcile interrupted operations.

### Startup Crash Reconciliation (`OperationJournal.recoverStale`)
- Interrupted operations in `started` or `executing` status are inspected.
- Active operations in memory (`isLocallyActive`) and recent operations updated within `olderThan` are preserved to prevent abandoning operations currently computing in an engine.
- Operations with committed rows (`tasks` or `reminders` stamped with `op_id`) are settled to `committed`. Operations with no committed rows are transitioned to `abandoned`.

### Persisted Action Recovery across Restart & Clock Advance
- In `session.dart::_turn`, recovery handles operations in both `executing` and `committed` states that possess a non-null persisted action (`CandidatePlan.fromActionJson(prior.action)`).
- When clock advances after an unacknowledged write, the session executes `retryRecover` using the persisted validated plan rather than replanning the relative prompt against the new clock.
- In `tools.dart::_createReminder`, prior committed reminders stamped with `op` are detected before running past-time validation.
- Reconstructed receipts use the actual stored primary reminder (`primary.triggerAt` and `primary.title`).
- If retry occurs after the original reminder time has passed:
  - No duplicate task or reminder rows are created.
  - No new or duplicate platform alarms are scheduled (`AlarmStatus.none`).
  - The reply truthfully reports that the reminder was already saved for that time (`"That reminder was already saved for ..."`), avoiding false claims of future delivery or invented delivery events.
- Fresh creates retain strict future-time validation (`Reminder time is in the past.`).

---

## 4. Test Evidence & Verification

### Targeted P2 Regressions & Architecture Tests
- `test/p2_restart_time_regression_test.dart` (4/4 passed):
  1. `startup recovery preserves the committed reminder time after clock advances`: passes; verifies stored 10:10 AM time is preserved when clock advances to 10:05.
  2. `startup recovery after original time passed produces no duplicate alarm or invented delivery claim`: passes; verifies clock advance to 10:20 (past 10:10) produces 0 duplicate rows, 0 duplicate alarms, receipt time 10:10, and truthful "already saved" reply without future delivery claims.
  3. `startup recovery at exact trigger boundary treats non-future time as already saved`: passes; verifies clock at exactly 10:10 reports already saved with `AlarmStatus.none`.
  4. `fresh create strictly validates against past times`: passes; confirms past time throws `ToolError`.
- Composition & architecture suite (112/112 passed):
  - `test/p2_architecture_test.dart`
  - `test/p2_composition_regression_test.dart`
  - `test/temporal_parent_regression_test.dart`
  - `test/temporal_session_test.dart`
  - `test/temporal_test.dart`
  - `test/turn_diagnostics_test.dart`

### Code Analysis
- `flutter analyze`: **0 issues found** (clean).

### Evaluation Corpus Freeze Validation
- `python3 -I eval/validate.py --summary`:
  - 102 dev + 34 held-out = 136 single-turn; 23 multi-turn.
  - Status: **OK**. Held-out files unread.

### Full Test Suite Execution
- **Legacy Mode (`CORENYTH_INTERPRETER=legacy`):**
  - **390 passed, 1 failed** (391 total tests).
  - Failing test: `test/assistant_home_test.dart: initial chat, send, new chat, switch with history, delete` (ambiguous `ListTile` widget finder descending from `ChatSidebar`). This is the known pre-existing baseline UI failure owned by P4.
- **Unified Mode (`CORENYTH_INTERPRETER=unified`):**
  - **390 passed, 1 failed** (391 total tests).
  - Failing test: same known baseline `assistant_home_test.dart` sidebar finder failure.

---

## 5. Limitations & Deferred Items

1. **Baseline UI Finder Failure (`assistant_home_test.dart`):** Ambiguous widget finder for sidebar chat items in widget test environment. Deferred to P4 (UI & interaction polish).
2. **Device Hardware Alarms & On-Device SLM Inference:** Platform exact alarms and native GGUF/ONNX execution on connected Android hardware remain software-mocked/abstracted in unit tests; real-device verification is deferred to P5.

---

## 6. Handoff Contract for P3

Stage P3 (Semantic model & grammar alignment) can assume:
- Unified coordinator in `lib/assistant/session.dart` with dual-interpreter support and stable `RouteId` priority ordering.
- Shared contract definitions in `lib/assistant/turn_contract.dart` (`CandidatePlan`, `Validation`, `ExecutionReceipt`, `TurnRecord`).
- Bounded model budget (`_budget.plan` / `_budget.reply`) preventing runaway loops or duplicate greedy calls.
- Strict authorization classification via `lib/assistant/authorization.dart` protecting all state-mutating actions.
- Operation journal (`OperationJournal`) active in production `AppServices` with durable turn identity, crash recovery, and idempotent stamped-row replay.
