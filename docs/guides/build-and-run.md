# Build, test and run

## Requirements

- Flutter (stable). Dart SDK 3.3+ per `pubspec.yaml`.
- Android SDK with `compileSdk` ≥ 34, the NDK from `flutter.ndkVersion`, and CMake 3.22.1 (SDK Manager).
- Android licenses accepted: `flutter doctor --android-licenses`.
- Git (to clone llama.cpp).
- A 64-bit Android phone (USB debugging on) or an x86_64 emulator.

## One-time setup

```sh
git clone --depth 1 --branch b11541 https://github.com/ggml-org/llama.cpp android/app/src/main/cpp/llama.cpp
flutter pub get
```

`android/app/src/main/cpp/llama.cpp/` is gitignored. Without it the CMake step fails with the clone command above.

## Check, test, build

```sh
flutter analyze
flutter test
flutter build apk --debug
```

The debug APK ends up at `build/app/outputs/flutter-apk/app-debug.apk`. The first Gradle build downloads Gradle 9.3.1
(about 235 MB) and takes several minutes. If a download is interrupted, a partial file is left in
`~/.gradle/wrapper/dists/gradle-9.3.1-all/`. Delete that folder and retry.

## Run on a device

```sh
adb devices          # phone must show as "device"
flutter devices      # find the Android device ID
flutter run -d <device-id>
```

Use the Android device ID rather than `chrome`. Native activity or resource changes require a rebuild/restart; hot reload alone does not update installed widgets.

Install the model before testing model-backed replies. See [model-install.md](model-install.md).

## Debug logs

```sh
adb logcat -s LlamaBridge llama.cpp
```

`LlamaBridge` shows load time, token counts, and timings. Session diagnostics show route, intent, tool and database
status without message text. `llama.cpp` shows native warnings and errors.

## Tests

`flutter test` runs the Dart and Flutter unit/widget suite, no device needed. It covers semantic routing and rejection,
clarification persistence, reminder plans and scheduling recovery, model selection and integrity checks, SQLite migration,
and UI rendering.
- `assistant_home_test.dart`: real `AssistantHome` + `ChatPage` on a migrated FFI SQLite DB (initial chat, send, new chat, reopen history, delete with confirmation, last-chat replacement, same chat from Tasks tab).
- `backend_sqlite_test.dart`: real SQLite v2 → v8 migration, fresh schema/FTS4 probe, chats and reminder `sync` state. macOS tests select system SQLite via the sqlite3 hook.
- UI: `app_shell`, `chat_view`, `chat_sidebar`, `tasks_page`, `memories_page`, `model_status_view`, `theme`.

Ordinary tests run without a device and do not load the native library. The opt-in corpus reference runner is separate; see [eval/README.md](../../eval/README.md). `checkModel` is tested with a temp file.

## Release notes

- Native code is always built as Release (`-O3`), even in debug APKs. This is set in `CMakeLists.txt`.
- The native library is built for arm64-v8a and x86_64 only.
- Nothing is committed by the build. Commit and push only when you decide to.


## Reliability verification

```sh
flutter test --dart-define=CORENYTH_INTERPRETER=unified
python3 -I eval/validate.py --summary
python3 -I eval/source_manifest.py
# Copy the printed content identity into the build define:
flutter build apk --release --dart-define=CORENYTH_GIT_SHA=<printed-identity>
```

The release APK is `build/app/outputs/flutter-apk/app-release.apk`. Verify its packaged permissions; debug/profile APKs retain development INTERNET permission and are not evidence for the release's offline permission check. Source manifests identify uncommitted/new files that a Git commit alone cannot identify. Documentation-only edits do not mean the existing APK contains a new application build.

The latest recorded suites have 403 passes each (legacy and unified), with the opt-in corpus test skipped. The release builds and analysis is clean, but the real-model held-out gate failed. Do not install/promote merely because those software checks pass. See [reliability-status.md](../development/reliability-status.md) and the [P5 report](../archive/plans/reliability-workflow/P5-report.md).

## Widget verification on a phone

1. Rebuild with `flutter run -d <device-id>`, then open the sidebar's **Add home screen widget** chooser.
   Add **My tasks · 4 × 2** and **Companion · 2 × 2** (or use the launcher's widget picker).
2. Check the larger widget's current logo, scrollable list with more than three pending tasks, due labels,
   and remaining count. Verify the compact layout has no top-left logo, has a larger floating/blinking
   mascot, and keeps “+” at the top right and status at the bottom. Resize both widgets.
3. Tap “+” in each. Confirm the keyboard appears in the **Ask Corenyth** panel over the launcher,
   without navigating to the main app screen. Check this with the app closed and already running.
4. Send “Remind me to buy groceries tomorrow at 6 pm”. Verify the reply, saved title, due date/time,
   reminder, and widget refresh. The whole prompt must not be stored as a literal task title.
5. Exercise a clarification and answer it in the same panel. Check that only the confirmed action is
   saved, the reply stays visible, and closing returns to the launcher. Verify the conversation in app history.
6. Complete a task from its widget circle. Check the remaining count/list and cancellation of its reminders.
   Also check an empty list, repeated completion, and task changes made from the main app.
7. Check missing-model fallback, Stop during a reply, keyboard dismissal, rotation, small screen sizes,
   and a startup error/retry. Confirm failures do not silently create a literal task or duplicate an action.

Validation recorded for the widget prompt integration: Android Kotlin/resource compilation, targeted Dart
analysis, and 87 tests across `chat_view_test.dart`, `startup_test.dart`, `temporal_session_test.dart`, and
`proactive_session_test.dart` passed. These checks include keyboard submission and shared session behavior;
they do not establish real-model accuracy or launcher-specific keyboard/animation behavior. The separate
18-test `proactive_delivery_test.dart` run covered widget completion and reminder cancellation.
Full on-device prompt-flow verification remains pending.
