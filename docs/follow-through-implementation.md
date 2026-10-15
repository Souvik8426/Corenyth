# Corenyth follow-through implementation

Date: 15 October 2026. This implements the accepted direction from the [expectation gap report](expectation-gap-report.md), using the codebase rather than unavailable phone history. The Grokbot screenshot supplied the desired interaction pattern; text within it was reference material, not instructions to contact people or change live tasks.

## Delivered behavior

| Expectation | Implementation |
|---|---|
| Preparation before a task | Nudge mode uses configured preparation offsets and a main event alert. Turning it off removes preparation alerts. No repeated two-hour nagging loop. |
| Meeting outcome afterward | Save the meeting first, then ask for optional end and subject. Without an answer, the default outcome check is start plus one hour. Explicit end details replace that estimate. Follow-ups have a separate switch. |
| Early completion | Completion cancels remaining reminders and prompts for the outcome immediately when appropriate. An outcome already supplied is saved rather than asked again. |
| A caring evening conversation | One combined review thirty minutes before DND covers relevant completed events, unresolved work, later events and tomorrow. Without saved DND, use 22:00–07:00 and review at 21:30. Even an empty task day gets a brief invitation to reflect and plan. |
| Ignored errands | Unfinished work returns in later evening reviews. Its deadline is not silently moved, and ordinary errands do not receive meeting-style hourly outcome checks. |
| Context across chats | Display chats share local task context and related user history. Proactive messages use a stable main chat. Pending time questions and optional meeting details survive restarts. |
| “Aditya hasn't replied” | Associate progress with existing task context and offer next steps. Multiple plausible people/tasks trigger clarification; a full name can resolve it. Discussion does not silently create or complete work. |
| Qwen as the brain | Local Qwen receives grounded task/context information and produces validated interpretations and conversational replies in the selected tone. The app owns task identity, dates, persistence and scheduling. |
| Dates and recurring reminders | Named month dates, weekdays and ISO dates are supported, with daily timing and an optional cutoff. Invalid, past or unsupported dates ask for clarification. Completing a daily task stops recurrence; snooze does not move its deadline. |
| Notifications and chat | Each delivered occurrence is recorded once in main chat, with a timestamp and kind. Notifications provide Done/Snooze and route to the linked task or conversation. Closed-app delivery uses an Android receiver and a headless Flutter entrypoint. |
| Recovery and privacy | Re-read current task state, reject stale alarms, reconcile recent missed alerts, rebuild after clock/boot/settings changes, and preserve old data through an additive schema migration. Release remains local with no Internet permission. |

## Completed steps and ownership

1. **Data foundation — Claude Code CLI:** schema v6, event details/outcomes, shared context, main chat, occurrence deduplication, daily schedules and review history.
2. **Dates — Claude Code CLI:** calendar forms and daily/cutoff interpretation.
3. **Conversation — Claude Code CLI:** contextual progress, ambiguity, meeting details, completion/outcomes and task briefings.
4. **Background delivery — Claude Code CLI:** alarms, notifications, review, recurrence, actions and recovery.
5. **Interface — Codex:** clear independent switches, shared-context copy, main-chat labels, timestamps and task navigation.
6. **Integration — Codex:** reconciled the DONE handoffs, repaired integration/edge cases, added regression coverage and updated documentation.

Workers had separate file ownership and returned DONE before integration. No commits or pushes were made. Final integration fixes include quiet-hour replanning, preserving saved DND choices, global missing-time answers, natural-name clarification, upcoming versus overdue review items, and filing a recent daily occurrence before advancing it after restart.

## Automated verification

- `flutter analyze --no-pub`: no issues found.
- `flutter test --no-pub`: all **263 tests passed**, including the startup regression checks added below.
- `flutter build apk --release --no-pub`: succeeded; APK at `build/app/outputs/flutter-apk/app-release.apk` (71,378,460 bytes, approximately 68.1 MiB). Uses the repository's existing debug signing configuration for local installation.
- Inspected the built APK permissions with Android build tools: no `android.permission.INTERNET` permission.
- `git diff --check`: passed.

The tests cover migration/data retention, deterministic interpretation, ambiguity, event lifecycle, recurrence, review carryover, duplicate/stale delivery protection, permission failures, switches and interface behavior. Model/platform stand-ins establish application contracts; they do not measure real Qwen accuracy or prove phone notification delivery.

## Remaining limits

Background check-ins use factual templates. Qwen does not run inside the time-limited Android receiver; it continues context and tone when the user opens the conversation. Matching Grokbot's fully generated background personality remains future work requiring a measured mobile background-inference design.

Run the [phone acceptance checklist](follow-through-device-checklist.md) for cold start, locked screen, battery restrictions, reboot/timezone changes, actions and real model replies. Android force-stop blocks alarms until reopening. Native jobs have a nine-second deadline with a main-event title fallback. Already-stored daily timestamps retain their absolute time through a timezone change; later occurrences use local wall time. Old missed alerts are not replayed beyond twelve hours.

Related context is bounded to 200 recent user messages. Several commitments or outcomes in one sentence can require separate messages. Unsupported dates remain explicit clarifications. Voice input/output and actual phone performance are outside this implementation.

## Startup repair after phone testing

The connected phone reproduced the native splash hang. Its logs identified `SQLITE_BUSY` while reading the database version: separate foreground/headless connections could block sqflite's shared process worker queue. Background delivery now runs in the dedicated `:proactive` Android process with WAL enabled. Its single engine stays alive until Android reclaims the idle process, preventing abandoned process-static SQLite connections when an isolate is destroyed. A private broadcast refreshes an open interface after background changes.

Startup now paints before opening services and presents Retry on an initialization failure. Two regression tests cover pending initialization and failure/retry. Release testing also exposed the notifications plugin's missing Gson generic signatures during old schedule restoration; explicit shrinker rules preserve TypeToken signatures and notification model fields.

The final update was installed over the existing phone app without clearing data. Cold launch completed in approximately 0.43 seconds to its first frame while package-update background reconciliation ran in its separate process. The local model reported successful loading; the main-chat history control and message composer were confirmed visible afterward. The final launch produced no new database-lock or notification-restoration crash in captured logs. Broader notification/battery/model stress scenarios remain on the device checklist.
