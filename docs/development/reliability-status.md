# Reliability status — 19 October 2026

**Broad reliability acceptance was rejected.** The repairs below are implemented, but unseen phrasing still fails. This is a review candidate, not a claim that the assistant is fully fixed. The candidate was not installed on the phone.

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
