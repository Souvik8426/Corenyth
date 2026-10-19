# P0 report: reproducible baseline

**Status: partial.** The software artifacts are complete: the corpus, the validator, the instrumentation and the
baseline test. Every Flutter and adb check is **NOT RUN**, because this session could not execute those binaries
(details below). No baseline percentages are claimed.

Baseline: `c1d1ada` plus the pre-existing untracked `android/.kotlin/` and `docs/plans/`. Both are untouched.
No commits, stashes, phone access or installs were made.

## Scope

- Diagnostic instrumentation in the session, engine and model services. No change to routing or parsing behaviour.
- `docs/device-evaluation.md`.
- A frozen evaluation corpus with a validator, in `eval/`.
- A focused screenshot regression test, plus a test for the new diagnostics.

## Files changed

| File | Change |
|---|---|
| `lib/assistant/engine.dart` | Added three constants. `buildRevision` comes from `--dart-define=CORENYTH_GIT_SHA`. `promptContractVersion` is `plan-v1`. `promptFingerprint` is the first 12 hex of the SHA-256 over all fixed prompts and grammars. `LlamaChannelEngine.lastLoadError` records why a load failed: `native_false`, `no_plugin` or a native code. |
| `lib/services/app_services.dart` | Added `modelFailure` codes: `crashed_last_run`, `not_installed`, `sha256_mismatch`, `not_allowlisted` and `load:<code>:<id>`. Added `modelDiagnostics()`, which reports build, selected, active, load state and failure. Logs `model boot:` and `model load:`. Passes the diagnostics into each session. Load behaviour is unchanged. |
| `lib/assistant/session.dart` | Added an optional `modelDiagnostics` constructor argument. Each turn's `lastDiagnostics` now carries `route`, `fallback`, `clarify` and `prompt`, merged with the build/model identity. No message text is included. The return values of every route are unchanged. |
| `test/screenshot_within_test.dart` | New baseline regression test (corpus S-001). It uses the fixed time 07:41 and expects a single reminder at 07:51 with a clean title and no help dump. It has one case with the model unavailable and one with a valid Qwen extraction. **Expected RED at c1d1ada.** |
| `test/turn_diagnostics_test.dart` | New test for the instrumentation. It covers the route, prompt fingerprint, fallback codes, the absence of message text, and the load-error codes via a mocked channel. Expected GREEN. |
| `eval/README.md`, `eval/validate.py` | Corpus schema and rules; a stdlib-only validator with a freeze manifest. |
| `eval/corpus/{single_dev,single_heldout,multi_dev}.jsonl`, `FROZEN.json` | The frozen corpus. |
| `docs/device-evaluation.md` | Added the P0 capture procedure: build identity, phone, model codes, per-turn fields, a disposable-profile screenshot run, and the corpus. |

## Evidence

**Corpus.** `python3 -I eval/validate.py --summary` passes (OK). Output:
- Single-turn: 102 dev + 34 held-out = 136 cases. Multi-turn: 23 scenarios.
- By category (all/held-out): scheduling 31/6, updates 19/4, lists 15/4, progress 14/4, memory 14/4,
  ambiguity 15/4, negation 14/4, chat 14/4.
- By source: user_history 55, plan_matrix 22, gap_report 4, synthetic 78.
- Expected kinds: write 67, reply 31, answer 20, clarify 18.

**Validator self-checks.** I ran these in memory; no corpus file was modified.
- It rejects:
  - a write with no changes
  - a reply that lists changes
  - a reminder with no time
  - an unknown task ref
  - an unknown clarify field
  - a malformed datetime
- Altering held-out case H-S01 is detected through the per-case hash.
- The closest held-out/dev pair has a token Jaccard of 0.46 (H-N04 vs S-008); the validator's limit is 0.70. The
  closest pair overall is 0.80 (P-001 "Aditya hasn't replied" vs A-002 "Aditya still hasn't replied"). That pair is
  intentional: the first has one Aditya, the second two.
- Every historical failure is included verbatim, with its source cited. That covers the screenshot, device
  checklist rows 1–10, the screenshot reply and complaint messages, the time-first request, "Aditya hasn't
  replied", "I've called Kabir", and the daily-until-5-November request.
- Expected state (`expect`) is kept separate from preferred phrasing (`wording`), which does not gate.

**Local APK identity.** This is the build on this machine, not what is installed on the phone.
- `build/app/outputs/flutter-apk/app-debug.apk`: SHA-1 `8df94f4d63b1dd998d3a2df65cd880894ed9d0c6` (matches its
  `.sha1` file); SHA-256 `9bc36a7506066e0f6b4cab4574ac23b429da48dc681d0fe34b3d4b90d2df21e3`.
- Built 2026-10-19 07:39 +0530, debug, versionName 0.1.0, versionCode 1.
- All 26 `lib/` files at HEAD `c1d1ada` appear verbatim in its `kernel_blob.bin`. The APK predates the P0
  instrumentation: `CORENYTH_GIT_SHA` is absent from it.
- It ships `libllama_jni.so` for arm64-v8a and x86_64.
- **Installed APK on the phone: not captured.** Whether the phone runs this build is unverified.

**Toolchain.**
- Flutter 3.47.7 stable (framework `abaf9c52`, engine `deb28748`, Dart 3.13.5) is at
  `~/development/flutter`, read from `bin/cache/flutter.version.json`. The Android SDK is at
  `~/Library/Android/sdk`, which contains `platform-tools/adb`.
- Neither is on `PATH`. Running them by absolute path, or with `PATH=` prefixed, needed approval that this
  non-interactive session could not get.
- `.metadata` was created with Flutter revision `5fc34683`, which differs from the installed SDK. This is
  informational only.
- Missing setup: put `~/development/flutter/bin` and `platform-tools` on `PATH`, or allow those binaries.

**Native diagnostics (source inspection).** `nativeLoad` returns `JNI_FALSE` for two different failures: the model
file failed to load, or the context failed to initialise. Dart cannot tell them apart; only the logcat tag
`llama.cpp` (WARN/ERROR) does. An out-of-memory kill during load shows up only as the crash marker
(`crashed_last_run`) on the next boot. I made no native change: a native change could not be built or tested here.

## Checks NOT RUN (exact blocker: Flutter/adb execution not permitted in this session)

1. `flutter test`, the full suite. 266 pre-existing test declarations across 31 files (static count) have no
   recorded current result.
2. `flutter test test/screenshot_within_test.dart`: the RED capture. Its expected failure comes from tracing the
   source, not from a run.
3. `flutter test test/turn_diagnostics_test.dart`: the GREEN check of the instrumentation. The Dart edits are
   unverified by the compiler.
4. `flutter analyze`.
5. `flutter build apk` with `--dart-define=CORENYTH_GIT_SHA`. Build reproducibility is unverified.
6. `adb devices` and the read-only phone inventory: model, Android version, RAM, installed APK hash, model file
   and checksum, logcat.
7. The screenshot request in a disposable phone profile. This needs the user's consent and a phone session.
8. A corpus run in any mode (rules-only, 0.6B, 1.7B). No host runner exists yet; see the handoff.

## Baseline failures, classified (traced from source at c1d1ada, not executed)

| Case(s) | Predicted result | Class |
|---|---|---|
| S-001 screenshot | Asks "When should I remind you about "…meeting within 10 mins"?" and appends `supportedWhen`. On the rules path the title keeps "within 10 mins"; on the Qwen path a `when` of "within 10 mins" fails `resolveWhen`. | Temporal parser limitation: `_inRe` requires `\bin\s+`. It is then misreported as missing information: `_create` / `maybeClarify` asks for a time, and `ClarifyDraft.prompt` appends the full help text. |
| Screenshot banner | "Using Qwen3 0.6B (default)" with "Fell back from selected model". The cause is one of: crash marker (OOM), 1.7B not installed, SHA mismatch, or native load false. Which one is **unknown**; the `modelNote` text on the phone would tell. | Model-load fallback, cause not captured. |
| S-003 "after 10 min", S-014 "half an hour from now" | No duration recognised. | Temporal coverage. |
| S-024 "in an hour and a half" | `_inRe` matches "in an hour" and stops, giving 08:41 instead of 09:11. | Temporal: partial match. |
| A-001 "Meeting in 10 minutes at 9" | `_parse` returns on the first relative match and schedules 07:51. | Temporal conflict not detected (first match wins). |
| M-011, M-012 (preference across chats) | `_semantic` and `_converse` pass `const []` memories. | Memory not retrieved into prompts. |
| L-011, M-017 (task #12) | The model prompt is capped at 10 tasks. The rules `byTitle` path may still resolve the reference. | Context truncation, model path. |

Every other case is **unmeasured**.

## Unresolved risks

- The Dart changes have not been compiled. They are small and additive, but an unrun analyzer could reveal an
  issue.
- `test/screenshot_within_test.dart` will make the full suite red until P1. This is intentional and documented
  in the test. Do not skip it or weaken it.
- The pre-P0 APK cannot emit the new diagnostics. The phone needs a rebuilt APK, which the user installs into a
  test profile, before any turn-level evidence exists.
- Corpus expectations in `also_ok` follow the plan's proposed decisions (the "within" convention, disclosed
  defaults). If the user rejects one of those decisions, a reviewed re-freeze is needed.

## Contract handoff to P1

- Turn `test/screenshot_within_test.dart` GREEN without editing its expectations. Capture its RED output first:
  P0 could not.
- Use `lastDiagnostics['route' | 'fallback' | 'clarify' | 'prompt']`. Leave `clarify` and `fallback` codes
  additive; P4 builds on them.
- Do not read `eval/corpus/single_heldout.jsonl` while changing the parser or prompts. Dev cases tagged `within`,
  `after`, `short_unit`, `word_number`, `compound_duration`, `fraction_duration`, `temporal_conflict` and
  `deadline` are the P1 targets.
- Any prompt or grammar edit changes `promptFingerprint` automatically. Bump `promptContractVersion` when the
  meaning of the contract changes.
- Still needed:
  - A host corpus runner, with rules-only/forced-unavailable mode and a scripted-model mode, over the real
    SQLite repos. AppServices needs clock injection to support it.
  - A device runner, for P5.
  - Phone inventory once Flutter and adb can run.
