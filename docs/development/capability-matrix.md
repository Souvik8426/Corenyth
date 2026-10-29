# Capability matrix

Planning date: 29 October 2026. Maps product wording to actual storage, permission
requirements, receipts and unsupported variants. An Android scheduled notification is
**not** a wake-up alarm with ringing/snooze guarantees. Internal tasks are **not**
external calendar synchronization. Building those integrations requires separate scope.

| Request | Supported wording (examples) | Stored entity | Permissions | Truthful receipt | Missing information | Known unsupported |
|---|---|---|---|---|---|---|
| Reminder | "remind me to … at/in …", "set a reminder …" | `reminders` row (`kind=reminder`) plus optional linked task/pre/follow-up per prefs | Notification + exact-alarm for delivery; save still allowed when denied | "Okay, I'll remind you…" when schedulable; "Saved… but \<issue\>" when delivery blocked | Ask for time when absent; refuse unsupported date forms without guessing | Recurring weekly/monthly beyond daily; absolute distant dates the parser rejects; guaranteed ringing while force-stopped |
| Alarm request | User says "alarm" / "wake me" | Same reminder machinery as above (notification at trigger) | Same as reminder | Same as reminder; never claims phone alarm-clock ringing or snooze | Ask for time; do not invent a clock app alarm | System `AlarmClock` intent, snooze UI, full-screen wake lock as a dedicated alarm product |
| Task | "add a task…", "I have to … tomorrow", to-do without a precise alert | `tasks` row; optional due; may create linked reminders when timed | None for the row; notification perms for any linked alerts | Confirms the saved task/due; does not claim calendar sync | Day-only tasks may use documented defaults; day-only *calls/events* ask for time | Google/Apple Calendar write; multi-assignee project trackers |
| Note | Free-form note / remember-later without scheduling | Task or memory depending on phrasing (`remember that` → memory when eligible) | None | Confirms save; temporary plans are not forced into long-term memory | Clarify when intent is ambiguous between task and memory | Rich document notes, attachments, folders |
| Schedule / calendar question | "what's on my day", "pending tomorrow", "my schedule" | Read of local tasks/reminders only | None | Lists local items; never invents external events | Ask which day/target when ambiguous | Reading or writing Google Calendar / device CalendarProvider |
| Saved fact | "remember that…", "my name is…", preference statements | `memories` active row with provenance; supersession on correction | None | Confirms remember/forget; corrections supersede prior active slot | Refuse overlong/temporary content per rules; ask when deletion target is ambiguous | Background silent fact extraction; vector search; Mem0 sync |
| Cancellation | "cancel that reminder", "forget that one", "don't remind me…" | Disable/delete reminder or clear pending; negation blocks create | Cancel path uses scheduler cancel when a platform alarm existed | Reports cancelled/disabled; does not claim the OS already dropped a never-armed alarm | Ask which target when several match | Cancelling alarms that only exist in a third-party clock app |
| Correction | "actually …", "change … to …", "move … to …" | Edit task/reminder or supersede memory inside authorization + receipts | Same as create for rescheduled alerts | Confirms new state; old memory marked superseded | Ask when target/time missing or conflict | Silent rewrite of unrelated history; inventing a new fact while leaving the old one active |
| Detail request | "explain", "in detail", "tell me more", persisted outside retry | No domain write by itself; may bypass ordinary length cap | None | Longer prose allowed; still no unauthorized tool writes | N/A | Treating detail as authorization to mutate data |

## Classifier honesty

A finite deterministic grammar cannot classify arbitrary language perfectly. Uncertain
inputs keep existing interpretation. Core requests that embed outside words
("remind me to explain this code to Sam") stay in scope. Clearly outside first asks
refuse with zero model calls; an immediate similar retry may answer read-only via the
local model.
