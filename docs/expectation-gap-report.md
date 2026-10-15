# Corenyth: expectation gap report

Reviewed 15 October 2026 against the supplied conversation screenshot and this checkout.

## Main finding

The screenshot describes a personal assistant that keeps commitments alive: it remembers what matters, nudges at appropriate times, asks for progress, and changes its next action when you reply. Corenyth currently provides task storage, scheduled alerts, and one optional follow-up. Its largest gap is sustained follow-through, rather than basic reminder creation.

This is a source review, not an inspection of the installed app. The phone's database, task history, installed build, actual notification delivery, and real model responses were not available. Messages in the screenshot are examples of desired behavior, not instructions to create those tasks or contact those people. Existing tests were inspected; this review did not obtain a completed test run.

## What already exists

- Tasks, reminders, chat history, and personal memories are stored locally.
- Multiple alerts can be scheduled before a task, followed by its event alert and one optional check-in. Defaults are 30 and 10 minutes before, and 60 minutes after; extras default to off.
- Completing a task cancels its linked alerts. Moving it regenerates its stored alert plan. Scheduling and cancellation failures have durable retry records.
- Quiet hours filter early alerts and follow-ups. The explicitly scheduled event alert still fires.
- Permission checks and a test-notification control help expose delivery problems.
- Task and reminder answers come from database queries; model plans are validated before writes.

Keep these foundations. A replacement scheduling system is not justified by the screenshot.

## Gaps, ranked by contribution to the expected experience

| Priority | Screenshot expectation | Current code | Improvement |
|---|---|---|---|
| P1 | Preparation nudges, event outcome conversations, and one evening review | `reminderPlan` produces early alerts and one fixed follow-up; there is no daily review | Separate preparation alerts, event-end follow-ups, and a conversational day review 30 minutes before DND; reconcile each against task updates |
| P1 | Renew before 5 November, with a daily reminder at 8:46 AM | Named calendar dates are rejected by the date parser; `recurrence` exists in storage but is unused | Support calendar deadlines and daily recurrence with an end condition; confirm the interpreted date and year |
| P1 | “He hasn't replied” continues the relevant conversation | Task status is only pending/done; model planning has short active-chat history rather than global conversational context | Retrieve relevant tasks and global context, clarify competing matches, and discuss the next action before scheduling it |
| P1 | “What are the tasks?” includes today, coming up, deadlines, and when nudges start | Task lists show titles and due times; reminder lists are separate | Build a database-derived briefing grouped into today, overdue, upcoming, and undated commitments, including the next nudge |
| P2 | Nudges are visible as a continuous conversation | Alarms display saved notification text; only interactive turns append assistant replies to chat | Persist scheduled check-ins as task-linked conversation events, with deduplication and a clear destination chat |
| P2 | Reply directly to a nudge and stop or postpone it | Notifications have no Done/Snooze/reply actions; tapping opens the Tasks tab, without selecting the task | Start with Done and Snooze plus navigation to the specific task; add inline reply when contextual replies are supported |
| P2 | “Once the meeting is arranged, tell me the time and I'll set nudges” | One missing-time clarification per chat exists, but no structured task dependency links arranging a meeting to attending it | Preserve the arrangement task and create a separate meeting reminder only after the user supplies its time |
| P1 | Warm, contextual follow-up conversations using the selected tone | Background follow-ups use the fixed text “How did [title] go?…”; a profile tone does not change it | Use Qwen with retrieved facts to discuss outcomes, useful reminders, and tomorrow's plans; retain factual fallback wording if model generation is unavailable |
| P2 | Several commitments can be captured naturally | Detected compound commitments are refused and must be sent one at a time | Offer a reviewable split into separate tasks, each retaining its own date and reminder policy |
| P2 | Meeting preparation alerts start at 9 PM for a 10:30 PM meeting | Lead offsets are configurable globally, while per-reminder language exposes booleans for multiple/follow-up | Allow task-specific reminder timing so changing one meeting does not change unrelated tasks |
| P3 | A readable timeline with timestamps and task context | Chat messages exposed to the UI carry role/content only; timestamps are stored in SQLite but not displayed there | Show time/date separators and task-linked actions after the behavioral gaps are addressed |

P1 means necessary for the core experience; P2 reduces friction or adds context; P3 is presentation polish. These are product priorities, not severity ratings for code defects.

## Reliability and control need to accompany proactive follow-through

Repeated notifications multiply the cost of stale state. Every future check-in must be cancelled or replanned when the user completes, snoozes, cancels, or changes a task. A restored task should disclose whether reminders resume. Existing behavior deliberately leaves reminders off after restoring a completed task.

Quiet-hour settings currently affect plan generation; changing them does not automatically rebuild existing plans. Turning off multiple alerts also leaves existing plans intact. Those semantics need to be visible, or revised consistently, before promising a global “stop nudging” control. Turning follow-ups off already cancels queued follow-ups.

A scheduled alarm is not proof that the user saw it. The screenshot itself shows intended versus actual nudge times differing by minutes. Decide which reminders need precise delivery, and avoid promising precision before screen-off, reboot, battery-saver, and permission-change checks on the phone. Offline operation can support scheduled local nudges; it cannot establish whether someone replied in another app or whether a website/domain renewal happened without user input or an integration.

## Smallest useful delivery sequence

1. Define the task lifecycle and nudge limits together. Extend the existing task/alert plan instead of adding a second task store. Preserve migration data and cancellation retries.
2. Add calendar deadlines and daily recurrence. Keep deadline, next action time, and next nudge distinguishable: renewing a domain on 5 November is different from reminding you today at 8:46 AM.
3. Deliver the complete loop for one task: capture → confirm schedule → nudge → report progress/waiting/done → reschedule or stop. Add notification controls and specific-task navigation.
4. Add the daily briefing and task-linked check-in history. Then improve wording and multi-task capture.

Acceptance examples: “Remind me daily at 8:46 until I renew before 5 November”; “Aditya hasn't replied, check tomorrow”; “I've called Kabir” cancels every remaining linked nudge; arranging a meeting preserves its separate attendance reminder; a restart produces no duplicate check-ins; changed quiet hours and disabled permissions produce the documented behavior.

## Source evidence and implementation reach

- `lib/data/db.dart`: pending/done status, reserved recurrence, stored conversations, and migrations.
- `lib/data/repos.dart`: task mutations, linked cancellation, `followUpText`, `reminderPlan`, preferences, and reminder sync state.
- `lib/assistant/rule_engine.dart`: date restrictions, compound-task rejection, capture, and clarification handling.
- `lib/assistant/semantic.dart`, `engine.dart`, `session.dart`, and `tools.dart`: supported intents, task reference resolution, validation, list replies, and interactive chat persistence.
- `lib/services/reminder_scheduler.dart`: prewritten alarm text, permission checks, pending-operation retries, and tap payloads.
- `lib/main.dart`, `lib/ui/tasks_page.dart`, `reminder_settings.dart`, and `chat_view.dart`: notification navigation, task controls, preference semantics, and message display.
- `android/app/src/main/kotlin/com/corenyth/assistant/WidgetProvider.kt`: task schema consumer; keep compatible if storage changes.
- Existing checks to extend: `test/reminder_plan_test.dart`, `pa_plan_acceptance_test.dart`, `pa_completion_test.dart`, `pa_acceptance_test.dart`, and `reminder_status_test.dart`. Add lifecycle, recurrence, migration, and duplicate-delivery coverage where the selected design requires it. Keep fake repositories and schema fixtures aligned.
- `docs/known-gaps.md`, `data-model.md`, and `device-evaluation.md`: documented limits and device verification needs. Code takes precedence where documentation differs.

## Interview decisions and open choices

### Confirmed in interview round 1

- Corenyth should help finish commitments, including chasing progress, rather than only remind when asked.
- Settings should separately control nudge mode (frequent repeated messages) and follow-ups. The user accepts frequent messages when nudge mode is enabled. Exact cadence and stop rules remain undecided. The current multiple-alert implementation provides early alerts, not ongoing progress checks.
- Keep operation fully local. Qwen should understand the situation as the assistant's brain; Corenyth supplies the application behavior and execution. How much authority Qwen has over state changes remains to be settled.
- Check-ins should appear in both notifications and chat, linked to the same task. The reference screenshot comes from Grokbot, the user's current personal assistant.

### Confirmed in interview round 2

- Nudges are preparation/action reminders before the scheduled task or event. Examples: a meeting at 11 AM may have alerts at 10, 10:30, and 10:55; buying milk at 5 PM may have an alert at 4:30 and the main reminder at 5. These illustrate desired behavior, not yet universal default offsets.
- Follow-ups ask about the outcome after an event is expected to have ended. They may invite notes, not just a done/not-done response. An 11 AM meeting might receive a follow-up after noon. Expected duration and the relationship between explicit completion and follow-up timing remain undecided.
- If a task is ignored, ask whether it was completed at the end of the day, 30 minutes before the configured DND start. This supersedes the proposed two-hour repeat cadence and three-unanswered-nudge cap; those suggestions were not accepted. Digest grouping and the settings gate for this check remain undecided.
- Qwen should interpret progress updates using previous tasks and context. “Aditya hasn't replied” should be connected to the existing request to arrange a client meeting when the context supports that link. The assistant should discuss next steps, such as calling him later or arranging it yourself, with wording adapted to the selected tone. It should not turn every progress statement into a new task.
- Proactive messages belong in the main chat. Context is global; separate chats organize visible message history rather than isolate assistant understanding. Context selection must account for this, since current semantic planning uses only a short history from the active chat alongside global task data.

### Confirmed in interview round 3 (supersedes earlier open points)

- Save the meeting reminder first, then ask when it ends and what it is about. Details are optional; an unanswered question must not block the reminder. If no end time is supplied, schedule the outcome follow-up one hour after the event/reminder time, not one hour after a preparation nudge.
- If the user reports completion early, cancel the scheduled outcome follow-up and respond conversationally at once: ask how it went and whether anything important needs a later reminder. Exact wording follows context and the selected tone.
- The evening review belongs to the follow-ups setting and starts as one combined message 30 minutes before DND. It should be a caring conversation about the day: relevant events, outstanding errands, things worth remembering, and tomorrow's plans. Include completed events when their outcomes matter; do not restrict it to an overdue-task checklist or repeat questions already answered.
- Clarify ambiguous references rather than silently picking. This includes distinct people with a shared first name, such as Aditya Sharma and Aditya Kumar, as well as several plausible tasks involving one person.
- The user's caring-partner analogy describes the warmth and attentiveness of the evening conversation. The daytime assistant analogy describes preparation and schedule follow-through. No spouse persona or relationship simulation has been requested.

### Final user decisions and implementation authorization

- Use configured nudge offsets unless the user explicitly requests different timing. Qwen may suggest preparation changes rather than silently inventing a schedule.
- When no DND schedule is configured, default to 22:00–07:00. The evening review is therefore at 21:30 by default.
- Ask about unfinished tasks in the evening review. If repeatedly ignored, keep including them in future evening reviews. Do not automatically move their deadlines or create tomorrow's timed reminders.
- The user ended the interview, requested a final report and step-by-step implementation plan, and authorized CLI Claude Code agents to implement assigned steps. Codex may implement a separate portion where file ownership prevents conflicts. Wait for Claude's DONE outputs rather than supervising live work.
- Execution follows `corenyth-follow-through-plan.md`. Background Qwen generation, main-chat lifecycle, quiet-hour changes, and recovery are engineering choices to resolve against these requirements, not reasons to reopen the product interview.

## Final recommendation

Build the local assistant around three distinct interactions: preparation nudges, event outcome conversations, and the evening day review. Shared context and Qwen understanding are necessary for all three to feel connected. Preserve deterministic validation, scheduling, task identity and cancellation; the model interprets and converses rather than inventing task facts or assuming completion.

The implementation is split into data foundation, date interpretation, conversational lifecycle, background delivery, interface, and integrated acceptance checks. The plan records ownership, dependencies, validation, and progress. This report describes the pre-implementation gaps; completed behavior must be confirmed by the final execution report and device checklist.
