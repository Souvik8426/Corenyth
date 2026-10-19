# Device evaluation (real Qwen)

Unit tests use stand-in engines that return the plan a correct model would give. They prove the app's validation
and SQLite behaviour, not what Qwen3 actually outputs. Before claiming the assistant understands a phrasing, run
this on a phone with the model installed and loaded (Settings shows it loaded), using a fresh chat.

Watch `adb logcat | grep "turn timing"`: each turn prints timing plus `model` (called/invalid/failed/unavailable),
`intent`, `tool` and `db`. No message text is logged.

## Baseline capture (reliability plan P0)

Record every item below before judging a turn. Mark anything not captured as **not captured**; never fill it in
from memory. All commands are read-only. None of them installs, clears or changes anything on the phone.

**Build identity.** Build with the revision baked in, so the log names the checkout that produced the APK:
`flutter build apk --debug --dart-define=CORENYTH_GIT_SHA=$(git rev-parse --short HEAD)`. Record the output of
`git status --short`; uncommitted changes mean the revision alone does not identify the build. On the phone:
- `adb shell dumpsys package com.corenyth.assistant | grep -E "versionName|versionCode|lastUpdateTime"`
- `adb shell pm path com.corenyth.assistant`
- Copy that APK off the phone and compare its SHA-256 with `build/app/outputs/flutter-apk/app-debug.apk`. A
  mismatch means the installed build is not this checkout.

An older APK without the define, or one built before P0, logs `build: unknown` or no `build` key at all.

**Phone.**
- `adb shell getprop ro.product.model`, `ro.build.version.release` and `ro.build.version.sdk`
- `adb shell cat /proc/meminfo | head -3`
- `adb shell dumpsys battery | grep -E "level|temperature"`

**Model.** Logcat line `model boot:` prints at startup, and `model load:` after each load. Both list `selected`,
`active`, `load` and `load_failure`. The `load_failure` codes are:
- `crashed_last_run:<id>`: the previous native load never returned, typically an out-of-memory kill.
- `not_installed:<id>`
- `sha256_mismatch:<id>`
- `not_allowlisted`
- `load:native_false:<id>`: llama.cpp could not open the model or create its context. Logcat tag `llama.cpp`
  says which.
- `load:llama_unavailable:<id>`: native library missing.
- `load:llama_error:<id>`

The file checksum is the pinned SHA-256 in `lib/services/model_status.dart`. A load verifies it; the cached
digest sits under app storage as `.sha256_<id>`.

**Per turn.** The `turn timing ms:` line now also carries:
- `route`: explicit_memory | early | complaint | follow_through | semantic | rules | rule_plan
- `fallback`:
  - `engine_not_in_use`, `not_loaded` or `native_<code>`: the model did not run.
  - `invalid_plan`: model output that did not parse.
  - `rejected_<intent>`: a valid plan that the app refused.
- `clarify`: model_when_unresolved | unsupported_date | no_time_found | time_passed | rules_missing_time
- `prompt`: `plan-v1:<12-hex fingerprint of every prompt and grammar>`
- The build and model identity fields listed above.

The UI banner shows only the resident model, not the model that handled a turn. Judge the turn from `route` and
`model`.

**Screenshot request in a disposable profile.** Do this only with the user's consent. It never touches their main
profile's data.
1. The user creates a secondary Android user or guest profile.
2. They install the same APK there and install the model there.
3. In a fresh chat, send exactly `Can u remind me i have a meeting within 10 mins`.
4. Record the submission time, the reply, the `turn timing` line and the Tasks/Reminders state.

Repeat with the model forced unavailable: move the model file aside, inside the test profile only. The
fixed-time host equivalent is `test/screenshot_within_test.dart`, which is expected to fail at baseline `c1d1ada`.

**Corpus.** Use [`eval/README.md`](../../eval/README.md) for the frozen cases and `python3 -I eval/validate.py` to check them.

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


## 19 October repair candidate

The release APK and source content identity are recorded in `eval/results/apk-identity.json` and `source-manifest.json`. The packaged release has been checked for absence of INTERNET permission. Real local Qwen reference runs use a read-only copy of the phone's shared model file; its hash matches the catalog. They execute production Dart interpretation/execution against disposable SQLite databases and the same GBNF/tokenizer/greedy sampling path on host CPU. See [the P5 report](../archive/plans/reliability-workflow/P5-report.md) for final results and remaining gates.

This reference run does not install the candidate, inspect the phone's private assistant database, deliver notifications, establish phone latency/RAM limits, or prove behavior after reboot. Those checks must remain distinct from host model accuracy. Do not apply a constant timestamp shift to calendar-based corpus cases; use an injected fixed clock for isolated corpus runs and the real clock for physical alarm delivery.
