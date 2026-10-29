# Reliability status

**Broad reliability acceptance was rejected.** The repairs below are implemented, but unseen phrasing still fails. This is a review candidate, not a claim that the assistant is fully fixed. The candidate was not installed on the phone.

## Update — 29 October 2026: scope, clarification and first display

Implemented conversation-local scope handling, repeated-request allowance, selected-chat concision, reference-only memory framing, and day-only-call time clarification. Deterministic confirmations can reach the display callback before optional mood inference; turn completion still awaits that inference. See [request flow](../architecture/request-flow.md) for boundaries.

| Check | Recorded result |
|---|---|
| Complete legacy suite | 503 passed, 2 skipped |
| Complete unified suite | 503 passed, 2 skipped (before the final scope similarity refinement) |
| Final targeted policy/routing/temporal checks | 78 passed |
| Static analysis | No errors or warnings; existing informational lints remain |
| Frozen corpus integrity | Passed |
| Rules-only development state evaluation | 83 passed, 14 failed, 5 incomplete |
| Current tuned-model and device qualification | Not run; no phone connected or GGUF found in checked locations |

The rules-only run is saved as [recorded state](../../eval/results/rules-dev-2026-10-29.json) and [scored checks](../../eval/results/rules-dev-2026-10-29-score.json). It preceded the final scope similarity/profile refinement and concise-output changes, so it is a dated checkpoint rather than final-source qualification. The old result files were preserved. Unit-test success does not resolve corpus failures or incomplete checks. No new held-out accuracy or phone performance result is claimed.

## Update — 20 October 2026: model-driven replies and a fine-tuned 0.6B

Goal: the model, not code special cases, should understand messages and speak in the user's tone. Changes (uncommitted on the `claude/app-testing-scrcpy-5ea08c` worktree):

- One model call per turn. The plan carries a required toned `reply`; the app appends it after its exact confirmation, or uses it as the chat answer ([request flow](../architecture/request-flow.md#validation-execution-and-replies)).
- Plans are rejected only when unsafe or impossible: model-picked `#id`s, `#id title` refs and reworded durations are accepted; add/remind messages can never complete or delete.
- Day-only events ask their time instead of a silent 9 AM, and a "3pm, it's about X" answer stores the topic.
- Prompt: tone guide, five examples, per-message memories moved to the user turn, tasks listed by id, `Reply tone:` line. Prompt identity changed from `plan-v1:c2a43ba929ea` to `plan-v1:ecd2c474158f`, so **the corpus scores below were recorded with the old prompt and have not been rerun.**
- A Qwen3-0.6B LoRA fine-tune on 4,821 plan examples (MASSIVE en-US + generated; [training](../../training/README.md)) is now the **only** allowlisted model (`corenyth-0.6b-tuned`); the stock 0.6B/1.7B entries were removed.

| Check | Result |
|---|---|
| Legacy and unified unit/widget suites | 441 passed, 1 skipped, 2 failed in both (model-switching tests were replaced by single-model tests) — the mascot drawing and markdown styling tests, which also fail on the unmodified `36e8bbf` |
| Static analysis | No issues |
| Fine-tune validation (150 of 241 rows, same generator as training) | intent 85 → 148, task `#id` 116 → 149 (base vs tuned) |
| Phone, stock 0.6B with the new prompt (manual script) | Intents mostly right with the examples; tone setting had **no** effect (example replies copied) |
| Phone, fine-tuned 0.6B (manual script, 12 model turns) | All 12 read correctly, including "hi how are you", "thanks, that helps a lot", "Add a task to clean my room", "I've called Kabir"; tone followed only loosely; warm turns 3.3–4.3 s, 6.5–8 s after task list changes, ~17 s first turn |

The phone runs are short manual scripts, not an acceptance measurement. The held-out gate below still stands until the corpus is rerun with the new prompt and model.

## Implemented repairs

- Shared typed temporal resolution for relative/calendar times, conflicts, unsupported forms, deadlines and alert leads. The screenshot request “Can u remind me i have a meeting within 10 mins” resolves to a meeting reminder ten minutes later in regression tests.
- Common authorization, candidate validation and execution receipts for model and rule routes. Polite action requests are distinguished from information questions, hypotheticals and negation. Model titles/ranges cannot replace app-grounded request fields.
- Operation journal and task/reminder operation stamps for retry and restart recovery, including committed relative-time actions. Typed target picks survive restart; the unified interpreter remains opt-in.
- Local SQLite FTS4 memory retrieval into planning and reply prompts, provenance, bounded correction/supersession and deletion. Relevant tasks are ranked before caps. Deleted/replaced personal facts are excluded from historical prompt replay. **Mem0 is not connected.**
- A stable, constant-speed loader arc with reduced-motion support. Model health separates selected/resident model from last-answer source; details expose load failures.

## Recorded verification

| Check | Result |
|---|---|
| Legacy unit/widget suite | 403 passed; opt-in corpus runner skipped |
| Unified unit/widget suite | 403 passed; opt-in corpus runner skipped |
| Static analysis | No issues |
| Release build | Built; packaged INTERNET permission absent |
| Real Qwen development corpus, 102 cases | 97 pass, 0 fail, 5 incomplete |
| Real Qwen held-out corpus, 34 cases | 12 pass, 18 fail, 4 incomplete — acceptance failed |
| Model unavailable development corpus, 102 cases | 87 pass, 10 fail, 5 incomplete |

Incomplete checks are not passes. Host Qwen evaluation uses the catalog model file, production Dart interpretation/execution, disposable SQLite databases and a non-delivering scheduler. The C++ reference uses matching special-token parsing, GBNF and greedy sampling, but **4096 context tokens versus the app's 2048 default**, and a fresh load/context per invocation. It does not establish production context parity, warm phone latency, RAM or notification delivery.

The five development grounding responses were reviewed directly by Codex, not an independent human reviewer. Remaining wording issues include a repetitive progress acknowledgement, an assumed positive trip description and a weak joke. Automated state checks alone do not establish conversational quality.

## Remaining acceptance gates

1. Fix generalization across task reads/updates, scheduling and durable-memory interpretation without weakening authorization or adding literal held-out phrase rules. Compare the allowlisted 1.7B model before changing defaults.
2. Execute the 23 multi-turn JSONL scenarios; existing restart/cross-chat regression tests are not a substitute for that corpus run.
3. Establish context-budget parity and run an isolated phone flow for model load, warm latency/RAM, permission denial, real delivery, cancellation, process death and reboot recovery.
4. Keep the frozen corpus unchanged. A later acceptance claim needs a new independently authored sealed set; do not tune against the consumed held-out examples.

## Evidence and implementation details

- [Full verification report](../archive/plans/reliability-workflow/P5-report.md)
- [Plan and self-answered requirements review](../archive/plans/assistant-reliability-plan.md)
- [Evaluation corpus and runner](../../eval/README.md)
- [Recorded scores and identities](../../eval/results/)
- [Request flow](../architecture/request-flow.md), [data model](../architecture/data-model.md), [tools and validation](../architecture/tools-and-validation.md)

The recorded APK is revision `c1d1ada-dirty-20b1a29933ed`; its identity and checksum are in `eval/results/apk-identity.json`. Documentation updates do not rebuild that binary. No commit, push, phone installation or private phone database extraction was performed during the repair campaign.
