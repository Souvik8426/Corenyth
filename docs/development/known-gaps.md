# Known gaps

## Reliability acceptance

The current candidate is **not accepted for broad language reliability**. Actual Qwen3-0.6B host runs recorded 97 passes / 0 failures / 5 incomplete on development cases, but 12 passes / 18 failures / 4 incomplete on held-out cases. The latter fails the proposed accuracy gate. Model-unavailable development coverage is 87 passes / 10 failures / 5 incomplete. Incomplete checks are not passes. See [reliability status](reliability-status.md) and the [P5 report](../archive/plans/reliability-workflow/P5-report.md).

The release APK was built and checked for absence of INTERNET permission, but was not installed on the phone. Real phone delivery, latency/RAM and the multi-turn corpus remain open gates.

## Not built yet

- **Speech input and output.** sherpa-onnx VAD and streaming ASR into `AssistantSession.handle`. The `speak` callback
  exists in the session, but nothing calls TTS. `RECORD_AUDIO` is declared but never requested.
- **Voice barge-in.** Typed chat has Stop (per-session cancel); nothing interrupts by voice yet.
- **Optional 1.7B on real hardware.** Selection, SHA-256 check and fallback are implemented and tested with a mocked
  native channel only; RAM and latency are **not** measured. A native out-of-memory kill is detected only at the next
  start (a leftover load marker), which then re-selects 0.6B.
- **Unsupported dates.** "Next Friday", "next week", ambiguous numeric dates such as "12/03", "midnight" and "in 2 weeks"
  are not parsed. Weekdays, named month dates and ISO dates are supported. The app asks or lists the supported forms;
  it never guesses. Also supported: today/tonight/tomorrow,
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

- Model-first understanding has now been measured with the actual Qwen file on host CPU and still fails held-out language checks. This does not measure phone performance. Invalid or rejected plans use the rules fallback.
- Daily schedule start dates and deadlines with their own independent clock time still require clarification.

- Grammar-constrained output, streaming, cancel, KV reuse and memory-pressure release are tested in Dart with
  mocks only; they still need on-phone verification.
- The memory dedupe scan is O(n). Fine for thousands of rows; not for more.
- Priority words (`low`, `normal`, `medium`, `high`) are accepted by the validator only. The grammar allows only the
  digits 0–2.
- `embedding` column in `memories` is reserved and unused.
- Desktop and web runs are not supported. `sqflite_common_ffi` is a dev dependency for tests only; macOS tests select system SQLite through the sqlite3 build hook to execute real FTS4 queries. Fresh `onCreate` and v2 → v8 migration tests pass; the bundled sqlite3 test runtime alone does not supply FTS4.
- Reminder plans rebuild when quiet hours change; turning nudge mode off removes preparation alerts. Restoring a completed task keeps its reminders off (Tasks says so). Tasks from
  before v4 have no stored plan and keep the older shift-and-drop behaviour. Quiet hours never silence the event
  alert itself. A reminder linked to a task with `task_id` replaces that task's plan.
- "How did it go?" in Tasks appears only for tasks with a follow-up; other overdue tasks show "Overdue".
- A missing-time question is persisted globally across chats and restarts. A detour that is itself a bare time ("5pm") is taken as the answer.
- Typed “Which one?” picks persist under `pick:<chat>` across restart. They remain scoped to that chat and expire after six hours.
- Capture has deterministic guardrails: "I have to say…" may become a task. Timed meetings get reminders; timed errands use the nudge preference unless explicitly requested. Two commitments in one message ("buy eggs and call Mum") are refused with a
  request to send them one at a time.
- A cancelled turn keeps its user message in history with no assistant reply.
- Context matching uses task keywords and asks when several candidates fit; it is not a complete person/contact database. Reminder title commands match upcoming enabled reminders.
- Fast route rejects any negation/`or`/chained command and hands it to the model (or the rules' help reply).

## Follow-through device limits

- Closed-app check-ins use factual templates rather than running Qwen in a broadcast receiver. Selected tone and contextual prose apply to interactive responses; background personality is limited.
- Headless cold start, lock-screen notification actions, exact alarm permission changes, battery restrictions, reboot and timezone recovery need real-phone checks. Native jobs have a nine-second deadline and an event-title fallback.
- A daily occurrence already stored before a timezone change retains its absolute timestamp; subsequent daily occurrences use local wall time. Missed alerts older than twelve hours are not replayed.
- The global related-context scan is bounded to 200 recent user messages. Multiple commitments or several outcomes in one sentence may require separate messages. Mocked tests do not establish model accuracy; the measured host held-out result remains below acceptance.
