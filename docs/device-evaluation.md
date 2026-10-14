# Device evaluation (real Qwen)

Unit tests use stand-in engines that return the plan a correct model would give. They prove the app's validation
and SQLite behaviour, not what Qwen3 actually outputs. Before claiming the assistant understands a phrasing, run
this on a phone with the model installed and loaded (Settings shows it loaded), using a fresh chat.

Watch `adb logcat | grep "turn timing"`: each turn prints timing plus `model` (called/invalid/failed/unavailable),
`intent`, `tool` and `db`. No message text is logged.

| # | Say | Expect |
|---|-----|--------|
| 1 | Morning 8:10 am remind me i have to schedule a meet with ceo of komal goyal studios | reminder today 8:10 AM (or "already passed" question), intent create_reminder |
| 2 | Wow that was fast soo tell me what are the things which are pending for tomorrow | "Due tomorrow:" with only tomorrow's tasks; intent list |
| 3 | Remind me i have to call pratham bhaiya too | asks when; title without "too" |
| 4 | I hv to check dev console tomo | task due tomorrow 9 AM; the question from 3 still open |
| 5 | 5pm | reminder for pratham at 5 PM; `model` absent (no model call) |
| 6 | I'm done with buying milk | completes "buy milk" only (asks if several match) |
| 7 | don't remind me to call Bob | nothing saved |
| 8 | Explain how to delete tasks | nothing deleted |
| 9 | what's the capital of France | short honest reply, no task facts |
| 10 | 90+24-10*89898 | -898866, no model call |

Record for each: reply, `intent`, whether the rules took over (`lastFallbackReason`, shown under the chat), and
latency. Also note RAM/temperature for long sessions. Repeat with the 1.7B model if installed.

Notifications: Settings -> "Send a test notification" schedules one exact alarm 10 s ahead after checking
notification and exact-alarm permissions. "Android accepted it" is not delivery proof: confirm it appears with the
screen off, after a reboot (`adb reboot`, then `adb shell dumpsys alarm | grep com.corenyth.assistant`), and with battery saver on.
