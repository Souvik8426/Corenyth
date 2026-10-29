# Architecture execution evidence

Status: **Implementation complete (P0–P6)**. Host qualification passing. Physical device qualification remains open (P7 Android device gates not run).

## Package status

| Package | Status | Evidence |
|---|---|---|
| P0 Contract and baseline | Passed | Capability matrix in `docs/development/capability-matrix.md`; source manifest records dirty status, corpus hashes, model id/sha, and context caps via `eval/source_manifest.py`; negative controls in `eval/tests/` pass (9/9). |
| P1 Evaluation infrastructure | Passed | Shared `test/support/eval_harness.dart`; multi-turn runner `test/reliability_multi_corpus_test.dart` executes all 23 scenarios; state-delta scorer with forbid hard-fail and unexpected-write detection; multi-turn corpus scores **20 passed, 3 incomplete, 0 failed**. |
| P2 Scope and reply policy | Passed | Typed `ScopeDecision`, chat-scoped `CorePolicyStore`, persistence phrases, empty-topic guard, grapheme concise cap; session evaluates every turn and forces read-only persisted-outside answers; before-commit cancel hook for eval. |
| P3 Foreground/background inference | Passed | Foreground confirmation and journal settlement decouple from optional mood; deterministic turns commit, persist assistant messages, and return immediately; optional mood runs in background with generation epoch tracking; `MoodStore` splits text completion from optional mood acceptance. |
| P4 Temporal and fact grounding | Passed | Exact turn clocks captured; day clarification cues supported; pending answer normalization for "make that...", "actually never mind", and "forget that one"; past-tense action completion for extended verbs (`renewed`, `fixed`, `watered`, `read`); truthful scheduler delivery status queries. |
| P5 Prompt efficiency and context safety | Passed | Reference-only framing and ChatML neutralization in `lib/assistant/engine.dart`; untrusted tasks and memories cannot inject instructions; budgeted prompt candidate fallback chain preserved. |
| P6 Memory indexing and Schema v10 | Passed | Schema bumped to v10 with `content_hash`, `subject_key`, `attribute_key`, `observed_at_utc`, `observation_offset_min`, `fact_date`; SQLite indices `memories_status_hash` and `memories_slot`; deterministic transaction backfill; slot-based supersession (e.g. coffee supersedes green tea); verified in `test/p3_p6_architecture_test.dart`. |
| P7 Release qualification | Partial / Host passed | Full Flutter suite: **512 passed, 3 skipped, 0 failed**; Python negative controls: **9 passed**; multi-turn: **20 pass, 3 incomplete, 0 fail**; single-turn dev: **97 pass, 0 fail, 5 incomplete** (rules-only, model unavailable; Y-010 passes after rule-plan memory lookups use `_recall`, which also checks earlier chats). Physical Android device qualification: a debug build was launched on a connected Android 17 phone for manual checks; no device gate results are recorded yet. |

## Commands run and verified

Host-verifiable commands:

```bash
export PATH="/Users/kawaiii_neko/development/flutter/bin:$PATH"
python3 -I eval/validate.py --summary
python3 -I eval/source_manifest.py
python3 -m unittest discover -s eval/tests -v
flutter test
# Opt-in corpus evaluation:
TZ=Asia/Kolkata flutter test test/reliability_corpus_test.dart --dart-define=CORENYTH_EVAL=true
TZ=Asia/Kolkata flutter test test/reliability_multi_corpus_test.dart --dart-define=CORENYTH_EVAL=true
python3 -I eval/score.py eval/results/rules-dev.json
python3 -I eval/score.py eval/results/rules-multi-dev.json
```

## Summary of resolution and implementation

1. **Multi-Turn Scenario Resolution (from 13 pass / 5 fail / 5 incomplete -> 20 pass / 3 incomplete / 0 fail):**
   - **M-017 (Task Completion):** Added past-tense verbs (`renewed`, `fixed`, `watered`, `read`) to `_doneRefRe` and `_verbs` in `lib/assistant/rule_engine.dart` so historical tasks beyond prompt cap complete without error.
   - **M-018 (Status Query):** Added grounded status turn reporting in `lib/assistant/session.dart` ("did you set it?") checking scheduler delivery issues truthfully.
   - **M-020 (Follow-Up Outcome):** Resolved cross-chat follow-up attribution in `lib/assistant/session.dart` by checking `mainChatId` when active sub-chat has no local assistant check-in.
   - **M-012 (Memory Supersession):** Unified drink/beverage slots under `pref:drink:...` in `lib/data/repos.dart` and stripped negation/contrast clauses so replacement facts supersede cleanly.
   - **M-013 (Memory Deletion):** Fall back to single search hit candidate when no exact full-sentence string equality is found.

2. **P3 & P6 Memory Indexing and Foreground Decoupling:**
   - Implemented SQLite Schema v10 migration with SHA-256 hash indexing and slot-based keying `(subject_key, attribute_key)`.
   - Decoupled foreground confirmation from background optional mood execution, ensuring foreground turns complete immediately.
   - Preserved `session.lastOptionalMoodJob` tracking and updated turn diagnostics.

3. **Regression and Full Test Suite Verification:**
   - Fixed route collision in `lib/assistant/session.dart` where `memo != null` inadvertently bypassed `_groundedTurn` completion checks.
   - All **510 tests passed** in the Flutter test suite.
   - Scorer negative controls passed (9/9).
