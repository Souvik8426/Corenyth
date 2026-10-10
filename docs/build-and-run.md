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
flutter run
```

Install the model before testing replies. See [model-install.md](model-install.md).

## Debug logs

```sh
adb logcat -s LlamaBridge llama.cpp
```

`LlamaBridge` shows the load time, prompt and generation token counts, and timings. `llama.cpp` shows warnings and errors.
Right now the raw model output is logged too (`output: …`). See [known-gaps.md](known-gaps.md).

## Tests

`test/assistant_test.dart` has 5 tests:
- Tool-call parsing accepts valid output and rejects malformed output.
- Rule-engine output always passes the validator.
- The model-file check (`checkModel`).
- The load popup states.
- The grammar, examples and prompt.

Tests run without a device and do not load the native library. `checkModel` is tested with a temp file.

## Release notes

- Native code is always built as Release (`-O3`), even in debug APKs. This is set in `CMakeLists.txt`.
- The native library is built for arm64-v8a and x86_64 only.
- Nothing is committed by the build. Commit and push only when you decide to.
