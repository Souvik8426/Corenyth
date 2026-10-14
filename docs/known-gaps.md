# Known gaps

## Not built yet

- **Speech input and output.** sherpa-onnx VAD and streaming ASR into `AssistantSession.handle`. The `speak` callback
  exists in the session, but nothing calls TTS. `RECORD_AUDIO` is declared but never requested.
- **Voice barge-in.** Typed chat has Stop (per-session cancel); nothing interrupts by voice yet.
- **Optional 1.7B on real hardware.** Selection, SHA-256 check and fallback are implemented and tested with a mocked
  native channel only; RAM and latency are **not** measured. A native out-of-memory kill is detected only at the next
  start (a leftover load marker), which then re-selects 0.6B.
- **Notification action buttons** (Done/Snooze in the notification). A tap opens Tasks, which has Mark done /
  Postpone 1 hour.
- **Unsupported dates.** Weekdays ("on Friday"), month dates ("12 March"), "next week", "midnight" and "in 2 weeks"
  are not parsed. The app asks or lists the supported forms; it never guesses. Supported: today/tonight/tomorrow,
  morning/afternoon/evening, "at 7", "at 7pm", "7:30", noon, "in N minutes/hours". Defaults are disclosed (morning = 9 AM, afternoon = 3 PM, evening =
  7 PM; a day alone = 9 AM, or the next hour if that has passed; a bare "at 7" after 7 AM = 7 PM). Past times are
  asked about, never rolled to tomorrow.
- **Memory-pressure release on device.** Dart releases the model on `didHaveMemoryPressure` and reloads on the next
  inference; not yet verified on a phone. Native unload while a generation is running is the native worker's job.
- **Faster CPU kernels.** The default build uses baseline armv8-a. A dotprod build is faster but crashes on some
  Cortex-A53-only phones.
- **Telemetry and benchmarks** (load time, tokens/s, RAM) across devices.
- **32-bit phones.** No native library, so they use the rule engine only.

## Rough edges

- Model-first understanding is only verified with stand-in engines; real Qwen3-0.6B accuracy on slang and long
  sentences is unmeasured (see device-evaluation.md). When its plan is invalid or rejected, the regex rules answer.
- Weekdays, calendar dates and "next week" still aren't resolved by the app's date parser; they are asked about.

- Grammar-constrained output, streaming, cancel, KV reuse and memory-pressure release are tested in Dart with
  mocks only; they still need on-phone verification.
- The memory dedupe scan is O(n). Fine for thousands of rows; not for more.
- Priority words (`low`, `normal`, `medium`, `high`) are accepted by the validator only. The grammar allows only the
  digits 0–2.
- `recurrence` column exists but nothing reads or writes it.
- `embedding` column in `memories` is reserved and unused.
- Desktop and web runs are not supported. `sqflite_common_ffi` is a dev dependency for tests only; the host SQLite
  has no FTS4, so tests cover the v2 -> v5 migration, not a fresh `onCreate`.
- Reminder plans: quiet hours are read from the settings at the time a plan is (re)generated. Turning multiple alerts
  off doesn't change existing plans. Restoring a completed task keeps its reminders off (Tasks says so). Tasks from
  before v4 have no stored plan and keep the older shift-and-drop behaviour. Quiet hours never silence the event
  alert itself. A reminder linked to a task with `task_id` replaces that task's plan.
- "How did it go?" in Tasks appears only for tasks with a follow-up; other overdue tasks show "Overdue".
- A missing-time question stays open across detours and restarts, but only within the chat's last 30 messages; an
  older one counts as abandoned. A detour that is itself a bare time ("5pm") is taken as the answer.
- "Which one?" answered with a bare id ("#2" / "2") is per session in memory and lost on restart.
- Capture is pattern-based: "I have to say…" may become a task; "I have a <thing>" is captured only with a time and
  is saved as a task without an alert. Two commitments in one message ("buy eggs and call Mum") are refused with a
  request to send them one at a time.
- A cancelled turn keeps its user message in history with no assistant reply.
- Title matching is exact after normalizing case, punctuation and spaces; no fuzzy matching. Reminder titles
  match only upcoming enabled reminders.
- Fast route rejects any negation/`or`/chained command and hands it to the model (or the rules' help reply).
