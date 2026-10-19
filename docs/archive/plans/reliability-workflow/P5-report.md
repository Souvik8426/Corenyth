# P5 — verification complete; reliability acceptance rejected

**The broad reliability target is NOT met. Do not mark the overall plan complete or promote this candidate on the strength of unit tests.** Specific implementation repairs are present, but unseen phrasing still fails. The candidate has not been installed on the phone.

## Candidate and checks

- Revision: `c1d1ada-dirty-20b1a29933ed`. Content manifest: `eval/results/source-manifest.json`; all production files were checked against it after the build.
- Release APK: `/Users/kawaiii_neko/Documents/GitHub/Corenyth/build/app/outputs/flutter-apk/app-release.apk`; SHA-256 `c12f336e0f155b7d28dcfa9d4d8f12b6e072d3266d57da023a180cc1cd146fd2`. The baked revision was found in the arm64 binary. Packaged INTERNET permission: **absent**.
- Full legacy suite: **403 passed**, one opt-in corpus test skipped. Full unified suite: **403 passed**, same skip. Static analysis: **no issues**. Release build and whitespace check passed.
- Fresh production SQLite FTS4 retrieval, triggers, correction/deletion, prompt injection, source provenance and v2→v8 migration were exercised on macOS system SQLite. Android remains on platform sqflite. Storage-only fake tests were not accepted as retrieval evidence.
- The original screenshot request passes: at 07:41, the meeting reminder is saved for 07:51, with scheduling words removed from its title. Model-origin titles and unsupported partial time matches cannot replace app-grounded fields.
- The loader now rotates a constant arc at a constant speed, preserves its 40×40 shape, honors reduced motion and has an honest loading label. Widget tests cover animation geometry, success/failure/retry and narrow status layout.

## Actual local model evaluation

Model: `Qwen3-0.6B-Q4_0.gguf`, SHA-256 `24ccc1cc08429fadd236268f920e965a376603479ca70f499be8930169c2159b`; pinned llama.cpp `f2918cabbffe8abf8e2a90c1c089085fa116c2cf`. The file was copied read-only from shared Documents/localmodels and matches the catalog. No phone private database was read.

`eval/native_host.cpp` uses production tokenization with special-token parsing, the actual GBNF and greedy sampler, a 4096-token context and four host CPU threads. Production `LlamaChannelEngine` defaults to 2048 tokens, so this reference does not establish production context-budget parity. Production Dart interpretation, authorization, validation and tool execution run against disposable production-schema databases with a non-delivering scheduler. No second chat template surrounds the rendered ChatML. This is an accuracy reference, **not an Android latency or alarm-delivery measurement**.

| Run | Automated pass | Fail | Incomplete |
|---|---:|---:|---:|
| Qwen development (102) | 97 | 0 | 5 |
| Qwen held-out (34) | 12 | 18 | 4 |
| Model unavailable development (102) | 87 | 10 | 5 |

Incomplete checks are never counted as passes. Detailed state results are in `eval/results/*-score.json`; observations and actual replies are in the matching JSON records. The scorer is deliberately incomplete for some semantic/rubric/platform checks. Fixture environment overrides are flagged incomplete rather than claimed as executed.

Five development grounding cases were reviewed directly; see `development-wording-review.json`. They name the right task or possibility and leave state unchanged. Wording limitations remain: partial-progress acknowledgement adds little, one casual response assumes a trip was great, and a generated joke is weak. This is a Codex qualitative review, not an independent human review or proof of general conversational quality.

Held-out inputs and expected labels were not inspected while tuning. An earlier candidate's held-out output remained unscored/uninspected while development-only fixes continued; the table is the frozen final candidate's fresh run. **No production changes were made after observing the final held-out result.** The generalization gap is real: development success must not be presented as overall accuracy. The held-out category counts show failures in scheduling, updates, lists and memory. Observed failures were predominantly missing actions/answers, not a license to loosen authorization or guess missing fields.

## Gates still open

1. Unseen-phrasing accuracy does not meet the proposed ≥95% overall / ≥90% category gate. The unified interpreter remains an opt-in rollback/comparison path; it was not promoted.
2. The 23 multi-turn JSONL scenarios have not been executed by the corpus runner. Existing multi-turn, cross-chat, restart, operation-replay and permission regression tests pass, but must not be counted as executed corpus scenarios.
3. Production context-budget parity, actual phone model loading after this build, warm latency/RAM, notification permission denial, real alarm delivery, process death, reboot recovery and cancellation delivery are not verified by host tests. No test reminders or user-data changes were made on the phone.
4. Model-unavailable operation is degraded; it must not imply the same language coverage as loaded Qwen.

## Required next implementation cycle

Address the intent-contract/generalization gap rather than add literal held-out phrasing rules. Improve task read/update interpretation and durable-memory normalization/recall with explicit evidence and typed memory operations; preserve the single validator/executor and no-write clarifications. Compare the already allowlisted 1.7B model on the same development contract before changing model defaults. Create a **new, independently authored sealed evaluation set** for a later acceptance claim; keep the existing frozen corpus unchanged and do not tune against its held-out examples. Run the missing multi-turn corpus, then use an isolated phone test flow for physical delivery and performance before promotion.

## Cleanup

The agy worker was terminated. Its 36 temporary permission rules were removed while preserving unrelated settings. No commit, push, app installation or private phone-data extraction was performed. The unrelated `android/.kotlin/` directory was left alone.
