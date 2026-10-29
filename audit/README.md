# Code audit — 2026-10-26

Scope: current uncommitted working tree; static inspection and host Flutter tests only. No app, emulator, or device launched during this audit. Production source was not changed. This is a focused audit, not proof that every app defect has been found.

## Results

- Existing suite: **463 passed, 2 skipped, 5 failed**. All five failures report host SQLite `no such module: fts4`; they affect fresh-create and memory-retrieval tests. This does not prove an Android SQLite defect.
- New desired-behavior probes: **6 failed**, reproducing the six defects below. Kept outside `test/` so they do not change the default suite's baseline.
- Static analysis: **1 warning**: unresolved `package:flutter_lints/flutter.yaml` include.

| Probe / defect | Observed behavior | Main source |
| --- | --- | --- |
| Mood at completion | Happy during draft, calm after completion with ID-less UI messages | `lib/main.dart` `_send`; `lib/ui/chat_view.dart` `_emotion` |
| Mood before text | Valid happy event ignored until an assistant draft exists | `lib/ui/chat_view.dart` `_emotion` |
| Same-page mood notification | Local scope changes to happy, callback receives no update | `lib/ui/chat_view.dart` `didUpdateWidget` |
| Stream split number | Partial `1` from grounded `12` permanently blocks stream; final answer accepted | `lib/assistant/session.dart` `_semantic`; `lib/assistant/follow_through.dart` `safeReply` |
| Older backups | Version-1 manifest rejected although data parser supports it | `lib/services/backup/backup_format.dart` `BackupManifest.parse` |
| Configured tone | Direct render includes chosen tone; native prompt candidates lose it | `lib/assistant/engine.dart` `Prompt._with` |

The model is a protocol stand-in. These tests do not measure real model accuracy, Android rendering, or hardware speed. The UI probes mirror the current message shapes and isolate view behavior; the repair prompt additionally requires actual ChatPage integration coverage.

## Reproduction

```sh
flutter test --no-pub audit/code_audit_regression_test.dart --reporter expanded
flutter test --no-pub --reporter expanded
flutter analyze --no-pub
```

See `regression-results.log`, `existing-suite-results.log`, and `analyzer-results.log` for captured output. Regression log line numbers precede removal of one unused import; test names remain unchanged. See root `zcodefixprompt.md` for implementation instructions, priorities, acceptance criteria, constraints, and separate unconfirmed review targets. Existing `zcodeprompt.md` was preserved.
