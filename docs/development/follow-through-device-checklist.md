# Follow-through: phone acceptance checklist

Use a test profile and disposable tasks. The repository does not contain your phone's task history. Automated tests validate application contracts, not Qwen accuracy or Android delivery.

## Basic setup

Install the resulting build without clearing existing data. Confirm old tasks, memories, and chats remain. Load the installed Qwen model and note the selected model. Enable notifications and exact alarms. Keep mobile data/Wi-Fi off during the core scenarios to confirm the local operation promised by the product.

Enable nudge mode and follow-ups separately as each scenario requires. Without saved DND hours, expect 10 PM–7 AM and an evening review at 9:30 PM. For a short test, temporarily move DND start so DND minus 30 minutes is a few minutes away, then restore the desired hours.

## Scenarios

| Scenario | Expected result | Record |
|---|---|---|
| “I have a meeting at 11 AM” (choose a future time during testing) | Reminder saves first; assistant asks when it ends and what it is about. Leaving this unanswered retains the reminder and a follow-up at start+1 hour when enabled. | Reply, task, alerts |
| Supply meeting end time and subject | Existing meeting is updated; its outcome check moves to the supplied end, without duplicating the task or reminders. | Before/after times |
| Report “the meeting is done” before its scheduled end | Future outcome alarm cancels; assistant immediately asks about the result and useful later reminders. | Reply and no later duplicate |
| Describe the outcome in the completion message | Assistant responds to the supplied information rather than asking the same question again. | Reply |
| Add a milk errand at 5 PM, ignore its alerts | Evening review asks whether it was done; it does not claim completion or silently move the deadline. | Review content |
| Ignore that evening review too | The same pending errand remains in the next evening review, with no new timed errand deadline. | Following-day review |
| Several tasks and meetings during a day | One combined evening conversation covers relevant outcomes, unresolved tasks, and tomorrow. Already discussed outcomes are not repeatedly requested. | Message count/content |
| A task about Aditya arranging a client meeting, then “Aditya hasn't replied” in another chat | Uses the earlier situation and offers next-step choices, without creating a new task called “Aditya hasn't replied.” | Reply and task count |
| Separate tasks involving Aditya Sharma and Aditya Kumar; say “Aditya hasn't replied” | Asks which person/task; no silent choice or mutation. | Clarification |
| Ask for today's tasks and coming deadlines | Names/dates come from actual local tasks, with a useful briefing and next alert details where available. | Compare with Tasks |
| Daily at 8:46 AM until 5 November | Confirms the interpreted date/year; daily occurrences stop on completion or the specified end condition. Invalid dates are refused/clarified. | Saved rule and next occurrence |
| Disable nudges, leave follow-ups on | Preparation alerts stop according to the documented settings behavior; outcome/evening checks remain. Main reminder behavior is disclosed. | Notifications/chat |
| Disable follow-ups | Queued outcome and evening checks stop. Nudges are independently controlled. | No stale follow-up |
| Change DND start | Evening review moves to 30 minutes before the new start; old scheduled review does not duplicate it. | Old/new schedule |
| Tap a proactive notification | Opens the main conversation with relevant context; specific-task actions identify the correct task. | Destination/action |
| Done/Snooze on a notification, if provided | Changes only the linked task/occurrence; no duplicate task, obsolete nudge, or silent deadline change. | Task state and next alert |

## Background and recovery

Repeat delivery with the app closed normally, screen locked, battery saver enabled, and after reboot. Android force-stop is a separate OS restriction: do not treat force-stopped delivery as guaranteed. Change device timezone and confirm the documented local-time behavior. Revoke notification/exact-alarm permissions, then reopen: the app must explain delivery limitations without claiming a reminder was seen.

For each delivered message compare notification text with its main-chat record. Check that reopening repeatedly does not duplicate check-ins, replay every missed daily occurrence, or resurrect cancelled alarms. Completing/deleting/renaming/postponing a task must leave no obsolete future messages. Deleting a display chat must follow the documented global-context/history behavior and preserve independent tasks.

## Model and performance evidence

Try the progress and ambiguity examples with the real model, not only fallback rules. Record the response, whether fallback occurred, elapsed time, and any incorrect state changes. Confirm the chosen tone changes wording without changing facts. Repeat one long conversation and several task switches to expose context truncation, stale state, or memory-pressure failures.

Check the final implementation report for background-generation limits. A saved factual background message and a Qwen-generated conversational response after opening are different capabilities; verify each separately. An accepted alarm is not proof of delivery.
