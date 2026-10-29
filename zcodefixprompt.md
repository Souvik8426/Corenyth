# Corenyth: repair confirmed code-audit failures

You are implementing repairs in this Flutter/Android project. Read this entire prompt before editing. Preserve existing uncommitted work and `zcodeprompt.md`. Do not reset the checkout. Implement the fixes below; do not merely provide another plan.

## Constraints

- Validate using source inspection, static analysis, and automated unit/widget/database tests. Do not launch the app, emulator, scrcpy, or interact with a device.
- Keep emotion interpretation model-driven. Do not add phrase lists, sentiment keywords, regex emotion classifiers, canned case handlers, or retrain the model. Deterministic schema validation, event routing, and mapping model labels to animation states are appropriate.
- Stream actual model output before generation completes. Do not simulate streaming by progressively revealing a completed answer.
- Preserve task/reminder authorization, grounded answers, cancellation, conversation isolation, and database integrity. Do not weaken safety checks simply to make streaming tests pass.
- Avoid broad refactors or unrelated dependency upgrades. Make each repair reviewable and explain its tests.

## Audit evidence and how to reproduce

The audit added `audit/code_audit_regression_test.dart`, outside the default `test/` suite. It contains six desired-behavior tests that all fail on the audited working tree. These failures are intentional evidence, not fixes. Run:

```sh
flutter test --no-pub audit/code_audit_regression_test.dart --reporter expanded
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
```

The probes use a deterministic stand-in for the model and real migrated host SQLite storage. Widget tests render in Flutter's test harness; no application/device was launched. They establish orchestration defects, not the real model's emotional accuracy or on-device latency. The migrated SQLite fixture deliberately lacks FTS and is not evidence that fresh database creation works.

## 1. P1: keep the saved message identity when a turn completes

Evidence: `lib/main.dart`, `_ChatPageState._send`, appends both user and assistant `Message` objects without IDs. The session separately persists the user row and emits a `TurnMood` tied to that row. `MoodController.history` uses the saved row ID, whereas `ChatView._emotion` looks up the ID on the displayed user message. Streaming temporarily uses `pendingEmotion`; completion removes that path, and the ID-less user row resolves to calm.

Reproducer: `AUDIT mood completion follows live turn` first verifies the streaming mascot is happy, completes the turn using the same ID-less message shape as `_send`, and observes calm despite a saved happy reading.

Implement a reliable association between the optimistic UI message, session operation, and persisted user row. Prefer a typed turn/result event or explicitly reconciled repository result. Do not match messages by text or choose the newest database row globally: duplicate text, retries, and multiple conversations make those unsafe. Reconcile identity before clearing live state. Preserve history selection and avoid creating duplicate messages when synchronizing.

Acceptance: streaming and completed views retain the same accepted mood; reopening shows it too. Add coverage through the actual ChatPage/session boundary, not only `ChatView`. Test identical consecutive messages, retry/cancel, and another conversation. Update the regression fixture to represent the repaired identity contract rather than adding a global pending-mood fallback to arbitrary ID-less historical rows.

## 2. P2: display a model mood before reply text exists

Evidence: `lib/ui/chat_view.dart`, `_emotion`, requires an assistant draft and non-null `streamingText` before considering `pendingEmotion`. The model contract places emotion first. A valid emotion event can therefore arrive while the user turn alone is visible; the current implementation ignores it. Buffered action replies have the same delay.

Reproducer: `AUDIT mood before_text follows live turn` supplies a valid pending happy reading with no reply draft and observes calm.

Represent the active submitted turn explicitly, independently of reply text. Associate it with the correct exchange and operation ID. Use its validated model mood as soon as it arrives, while retaining stored moods for selected older exchanges. Unknown stays neutral. A typing/loading animation must not overwrite the semantic emotion.

Acceptance: emotion-only envelope changes the latest active exchange before any prose; viewing an older exchange remains unchanged; late events after stop, disposal, or conversation change are ignored. Test action plans whose response remains buffered until execution commits.

## 3. P2: publish emotion changes on the selected page

Evidence: `ChatView.didUpdateWidget` invokes `onEmotionChanged` only when the selected page index changes. An emotion update on the same page does not notify the callback. `lib/main.dart` forwards this callback to the surrounding mascot state.

Reproducer: `AUDIT mood callback follows live turn` verifies a happy local scope while the callback receives no happy update.

Publish changes to the effective selected emotion even when the page index is stable. Handle initial selection and subsequent changes consistently. Compare meaningful emotion state, avoid redundant notifications and rebuild loops, and do not trigger parent `setState` during build. Guard deferred notifications against disposal and stale selected pages.

Acceptance: local and surrounding mascots agree after live mood arrival, finalization, and history navigation; an identical emotion update causes no notification loop; stale scheduled callbacks do not override a newer conversation/selection.

## 4. P1: do not permanently reject valid streamed token prefixes

Evidence: `lib/assistant/session.dart`, `_semantic`, runs `safeReply` on each cumulative partial string and permanently sets `streamBlocked` after the first failure. `_converse` has a similar latch. `safeReply` in `lib/assistant/follow_through.dart` compares digit sequences to the grounding text.

Confirmed example: user `I feel overwhelmed by these 12 ideas`; valid model reply `Those 12 ideas can wait. What feels heaviest?`. The first chunk ends in `Those 1`. The partial number `1` is not the grounded number `12`, so streaming is permanently withheld. The complete answer containing `12` is nevertheless accepted. The audit session test observes no streamed reply and diagnostics `stream: withheld`.

Implement incremental handling that distinguishes incomplete tokens from established violations. Hold an undecidable suffix until a boundary or completion makes it decidable. Revalidate as new data arrives; do not poison a turn because an unfinished token is temporarily ungrounded. Share the relevant logic between plan and reply paths without duplicating policy. Keep raw envelope JSON and control metadata out of the UI.

Do not simply remove validation or stream every raw substring. Define the safe release boundary for action claims and unsupported facts, retaining buffering for write confirmations until committed. A previously displayed false claim cannot be made safe by erasing it afterward. State explicitly what incremental checks guarantee and what remains held until final validation.

Acceptance: the confirmed split-number test streams before completion. Add boundary tests around numbers, escapes, punctuation, Unicode, incomplete JSON strings, and a final malformed envelope. Test genuine unsupported numbers and uncommitted action claims split across chunks. Use a completion gate to prove callbacks arrive while generation is still running, and verify final text has no duplication or missing characters. Check stop cancels pending coalescer flushes and late native events cannot resurrect a stopped draft. No additional model calls merely to animate text.

## 5. P1: restore version-1 backup compatibility

Evidence: `lib/services/backup/backup_format.dart` bumped the format to 2. `parseBackupData` accepts versions 1 through 2 and handles the absent older mood table, but `BackupManifest.parse` requires exact equality with version 2. `BackupService` validates the manifest before importing the data, so older archives never reach the compatibility path.

Reproducer: `AUDIT version 1 backup manifest remains readable` gets null and the error saying only version 2 is readable.

Make manifest and data compatibility policies agree for supported versions. Keep rejecting unsupported future versions, invalid versions, and malformed data. Validate manifest/data agreement; do not accept arbitrary mismatched combinations. Older backups must import without inventing historical mood records.

Acceptance: add a complete archived version-1 fixture through the public preview/import path, not just a parser test. Verify restored conversations/tasks and neutral fallback for missing moods. Test version-2 mood round-trip, future-version rejection, mismatched manifests/data, and rollback/no partial overwrite on invalid input. Preserve existing restore safeguards.

## 6. P2: preserve configured reply tone when budgeting prompts

Evidence: `lib/assistant/engine.dart`, `Prompt._with`, copies fields except `tone`. Every `candidates()` entry goes through `_with`; the native request uses `p.budgeted(...)`. Direct `render()` includes `Reply tone: professional`, but the candidate sent toward inference loses that selection. The generic list of available tones does not communicate which tone the user chose.

Reproducer: `AUDIT tone survives native prompt candidate construction` passes for direct render and fails for the first candidate.

Preserve tone through all prompt copies and budgeting stages. Inspect other prompt fields for equivalent omissions. Keep configured reply style separate from inferred user emotion. Do not replace the model with canned tone-specific text.

Acceptance: test every supported tone through candidate construction and budgeting, including history trimming and optional-context removal. Check the native request payload with a mocked bridge. Ensure current user text, contract, and essential grounding remain intact.

## 7. Restore trustworthy static and database checks

`analysis_options.yaml` includes `package:flutter_lints/flutter.yaml`, but `pubspec.yaml` does not declare that package. Restore a resolvable lint configuration using a compatible development dependency, then address actual findings without blanket suppression.

The existing host suite has also reported five failures caused by `no such module: fts4` in fresh database/memory-retrieval tests. Reproduce and inspect the host SQLite library selection and `hooks.user_defines.sqlite3` configuration. This is a confirmed host test-environment blocker; it does not establish that Android's SQLite lacks FTS4. Do not claim Android startup is broken on that evidence alone. Arrange an FTS-capable host test dependency or correct configuration and run the real fresh-create/retrieval tests. Do not mark them skipped or substitute the migration-only fixture to hide the problem.

## Additional review targets — not confirmed by the six probes

Inspect these paths and add evidence before classifying them as repaired bugs:

- `_storedMoods` in `lib/main.dart` force-unwraps a nullable `TurnMood.fromDbRow` result; invalid optional metadata should not make an entire conversation unloadable.
- `refresh()` reloads messages without their moods; check background/other-engine updates.
- `_stop()` does not immediately cancel `_coalescer`; cleanup occurs after the turn settles. Test a delayed model cancellation and queued UI flush.
- `_emitMood` launches persistence without awaiting it and swallows write errors. Establish completion/shutdown durability expectations and verify them.
- Early deterministic response paths may never call the model and therefore never emit emotion. Trace supported routes against the product requirement. If coverage is missing, integrate bounded model inference without new emotion case handlers or unnecessary extra calls on already-inferred turns.

## Completion requirements

1. Reproduce the six failures before changing implementation. Preserve these checks or replace them with stronger equivalent integration tests where the API changes.
2. Fix the causes in coherent steps. Move maintained regression tests into `test/` once repaired and adjust helper imports; keep no duplicate suites.
3. Run targeted checks after each relevant change, then static analysis and the full existing suite. Report exact pass/fail/skip counts and any remaining environmental blockers.
4. Measure perceived-performance behavior using gated model mocks and callback timestamps: first mood, first safe visible text, final completion, and update count. Do not report mock timings as device performance improvements. Keep UI updates coalesced without waiting for full completion.
5. Deliver a concise change summary, files changed, test evidence, and remaining limitations. Do not claim real-model emotion accuracy or device performance was tested. Do not launch the app/device without a new user request.
