# Corenyth follow-through implementation plan

Generated 15 October 2026. User authorized implementation and CLI Claude delegation; further product interviewing is closed. This plan uses the confirmed decisions in `docs/expectation-gap-report.md`.

## Product contract

- Entirely local. Qwen interprets context and discusses next actions; app code validates writes, dates, task identity, and notification delivery.
- Nudge mode uses the configured lead offsets, followed by the event-time reminder. No two-hour nagging loop.
- Follow-ups are separately enabled. Ask a meeting's end time and subject after saving its reminder. Unanswered details never block it; default follow-up is start plus one hour. Supplied end time replaces the estimate.
- Reporting a meeting finished cancels its future follow-up and asks about its outcome immediately, including anything worth reminding about later. Do not repeat an outcome already supplied.
- One warm evening review, 30 minutes before DND, discusses the day, unresolved errands, relevant event outcomes, and tomorrow. Default DND: 22:00–07:00, hence default review: 21:30. Unanswered tasks stay in later reviews; do not silently move deadlines or create new timed alerts.
- Global context across chats; separate chats organize display. Ask which person/task when ambiguous. Proactive messages go to one stable main chat.
- Show proactive check-ins in notifications and chat. Reconcile completion, deletion, snooze, preference changes, restart, and boot without duplicates. Do not add INTERNET permission.
- Support the screenshot's named dates and daily-until-complete reminder use case. Never guess unsupported/invalid dates or claim an external action happened.

## Execution rules

Claude Code CLI workers receive a file-based shared brief, exclusive file ownership, and a DONE report path. The parent does independent work and waits for exit/DONE; it does not inspect live transcripts or intervene in implementation. Only completed output is checked. No commits, pushes, deployment, dependency installation, or phone-data access. One test runner at a time. No bypass-permissions flag.

The safe split is by files, not an artificial equal line count: Claude owns data/assistant/platform, Codex owns UI/docs and final validation. Workers leave all changes uncommitted. Temporary prompts/logs/completion reports live in a fresh workflow directory.

## Dependency graph

T1 data ─────────┐
T2 dates ────────┼── T3 understanding/lifecycle ─────────────────────────── T6 acceptance
T1 data ──────── T4 proactive delivery ───────────────────────────────────┘
T1 data ──────── T5 UI ───────────────────────────────────────────────────┘

### T1: Local state and shared-context foundation
- **owner**: Claude Code CLI data agent
- **depends_on**: []
- **location**: `lib/data/`, `test/proactive_data_test.dart`, `test/backend_sqlite_test.dart`, `test/support/v2_db.dart`
- **description**: Add a data-preserving migration and small repository methods for event end/subject, global relevant context, stable main chat, idempotent proactive message records, recurring daily reminders, and daily review participation/history. Keep existing task/widget columns compatible. Add optional named `createdAt`, `taskId`, `kind` to Message; keep two-positional-argument construction valid. Expose `ConversationRepo.mainChatId = 'main'` and optional `ChatSummary.isMain` default false. New preferences default quiet hours to 22:00–07:00 when absent; preserve explicit saved choices. Supply an exact API/schema handoff for dependent workers.
- **validation**: Migration keeps old data; context spans chats; duplicate proactive event adds one message; completed/deleted tasks lose alarms; review retains ignored pending tasks; old constructors remain valid. Add focused regression tests.
- **status**: Completed
- **log**: Claude DONE: additive schema v6, shared context/main-chat/proactive records, event metadata, daily and review repositories. Parent reproduced and fixed quiet-end replanning, future snooze preservation, and settings-change reconciliation gaps. All 13 data tests pass. Migration preserves saved DND choices; an absent row defaults to22:00–07:00. Final integration remains T6.

### T2: Calendar and daily schedule interpretation
- **owner**: Claude Code CLI date agent
- **depends_on**: []
- **location**: `lib/assistant/rule_engine.dart`, optional `lib/assistant/calendar.dart`, `test/calendar_follow_through_test.dart` only; existing shared test adjustments belong to T6
- **description**: Extend the existing parser to named dates such as 5 November/Nov 5, weekdays, and explicit ISO dates; validate impossible dates and retain past-time clarification behavior. Parse daily timing and an optional until/deadline separately through a small documented helper for T3; preserve relative forms and existing callers. Do not implement persistence or recurrence execution here.
- **validation**: Tests for date/year boundaries, invalid dates, past dates, daily 08:46 until 5 November, and existing today/tomorrow/relative parsing. No writes for unsupported inputs.
- **status**: Completed
- **log**: Claude DONE: calendar dates, weekdays and parseDaily helper; all 7 focused parser tests pass. Parent also prevents a cutoff clock being mistaken for the daily reminder time. Date-only expectations in three legacy test files were updated by Claude and will be checked at integration.

### T3: Qwen context and conversational event lifecycle
- **owner**: Claude Code CLI assistant agent
- **depends_on**: [T1, T2]
- **location**: `lib/assistant/` except T2-owned files, `test/proactive_session_test.dart`, assistant fake repositories and existing affected assistant tests
- **description**: Integrate global relevant context and safe progress interpretation; resolve ambiguity with the user. Connect updates such as “Aditya hasn't replied” to existing work and discuss options instead of creating a task. Save timed meeting commitments with alerts, then collect end/subject optionally; default end to start+1 hour. Early completion cancels scheduled outcome check and starts outcome conversation. Support outcome notes and explicit requests for later reminders, daily recurrence helper, explicit task-specific timing, and database-derived task briefings. Preserve the arrangement task when separately creating an attendance reminder. Qwen wording follows profile tone; deterministic fallback stays honest and functional.
- **validation**: Acceptance tests for cross-chat progress, two Adityas, no invented mutations, meeting creation/detail answer/restart/early completion, recurrence integration, and no duplicated outcome question. Existing security/negation tests remain intact.
- **status**: Completed
- **log**: Claude DONE: global context, progress discussion, meeting details/outcomes, early completion, daily commands, briefing and grounded Qwen replies. Its15 tests passed; parent added/fixed natural-name clarification, nudge-mode errands, conversational day review, global missing-time answers, and ordinary errands using evening review instead of an hourly follow-up. All22 session tests pass. Final integration remains T6.

### T4: Proactive delivery, evening review, and recovery
- **owner**: Claude Code CLI platform agent
- **depends_on**: [T1]
- **location**: `lib/services/`, `lib/main.dart`, Android native/manifest files, `test/proactive_delivery_test.dart`, affected service/home tests
- **description**: First verify closed-app delivery feasibility using installed Android/plugin sources. Deliver task-linked nudges and outcome checks to both main chat and notifications. Produce one evening review at DND-30 minutes, default 21:30. Query actual pending/day events at delivery so obsolete schedules do not report stale tasks. Retain ignored tasks each evening without auto-rescheduling. Wire main-chat and specific-task navigation, resume refresh, snooze/done actions where safe, recurrence, boot/timezone/preference changes and idempotency. Daily recurrence ends on completion or the confirmed deadline; missed occurrences do not flood, and snooze must not silently move the deadline. Use existing local engine when available; do not run unbounded Qwen generation in a broadcast receiver. A factual background fallback must deliver with app closed; contextual conversation continues locally on open. Document any background-generation limit explicitly.
- **validation**: Tests for both switches independently, review grouping/carryover, schedule cancellation/rebuild, duplicate prevention, runtime permission failures, recurrence and reboot contract. Android compile check if available. Record real-phone checks separately.
- **status**: Completed
- **log**: Claude DONE: native/headless proactive delivery, main-chat records, actions, review and recovery. Codex integrated task navigation, complete notification text, review resilience and recent daily reboot catch-up. All 16 delivery tests pass; Android release build passed in T6.

### T5: Clear controls and readable shared-context timeline
- **owner**: Codex
- **depends_on**: [T1]
- **location**: `lib/ui/`, `test/chat_view_test.dart`, `test/chat_sidebar_test.dart`, `test/reminder_settings_test.dart`, new UI tests only
- **description**: Label nudge and follow-up modes accurately, explain the evening review and default DND, show main chat and shared-context semantics, and render message timestamps/proactive task context from optional metadata. Preserve accessibility, existing visual language, narrow-screen behavior, and existing controls. No new dependencies or backend edits while Claude owns them.
- **validation**: Focused widget tests for switch descriptions, main-chat label, timestamp rendering and narrow screens. Run after CLI workers finish to keep one test runner.
- **status**: Completed
- **log**: Controls, shared-context/main-chat copy, timestamps and proactive task labels implemented. Focused widget checks passed in the26-test combined run; final integration remains T6.

### T6: Integrated checks and final user report
- **owner**: Codex
- **depends_on**: [T1, T2, T3, T4, T5]
- **location**: `docs/`, this plan, integrated test/build outputs; minimal integration fixes after ownership is released
- **description**: Reconcile DONE reports, inspect final changes for requirement gaps, run analyzer and full relevant suite on the combined tree, repair integration failures, update architecture/known gaps and a phone acceptance checklist. State completed, deferred, failed, and device-only verification accurately.
- **validation**: All required automated checks pass or a concrete environment blocker is recorded. No cloud calls or external contacts by the product; no model accuracy/delivery claim based solely on mocks. No commits/pushes.
- **status**: Completed
- **log**: All four CLI workers returned DONE and released ownership. Integration fixes and documentation are complete. Analyzer is clean, all 261 tests pass, whitespace checks pass, and the release APK built successfully (68.1 MiB). Built APK permissions contain no INTERNET permission. Real-phone/Qwen checks remain explicitly unverified; see docs/follow-through-implementation.md and the device checklist. No commits or pushes.

## Ownership and handoff clarification after plan review

T2 edits no existing shared tests. T3 owns assistant tests and `test/backend_test.dart` fakes; T4 owns `test/proactive_delivery_test.dart`, `test/reminder_status_test.dart`, and `test/assistant_home_test.dart`; T5 owns UI tests listed in its task. Other legacy test adjustments belong to T6. T4 does not edit `lib/ui/`; it supplies navigation callbacks/state through `main.dart` and requests any required UI follow-through in its final handoff. T1's DONE report must specify occurrence identities, transactional idempotency, cancellation/retry intent behavior, separate deadline/reminder timing, and the exact delivery APIs for T4. The plan reviewer identified these dependencies before dispatch; no unresolved product questions are required.

## Documentation consulted

- Android alarm lifecycle: https://developer.android.com/develop/background-work/services/alarms
- Flutter platform channel calls: https://api.flutter.dev/flutter/services/MethodChannel-class.html
- Installed Flutter/local-notification package sources are the version-specific API reference during implementation.

## Assumptions used to avoid another interview

The main chat has a stable reserved identity and can be recreated after deletion. Deleting a display chat removes that history but not independent tasks. Quiet hours apply to optional proactive messages; explicit event alarms retain their current behavior. Reopening after downtime reconciles once rather than replaying a flood. Reminder precision and Qwen accuracy require separate phone testing. The implementation must explain any limit rather than silently claim it works.

