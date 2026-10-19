# Frozen evaluation corpus (P0)

Frozen 19 October 2026, before any prompt, grammar or parser change (baseline `c1d1ada`).
`python3 -I eval/validate.py --summary` checks the schema, the coverage gates and the freeze manifest.

| File | Contents |
|---|---|
| `corpus/single_dev.jsonl` | 102 single-turn cases. Implementers may study and test against these. |
| `corpus/single_heldout.jsonl` | 34 held-out single-turn variants (`H-` ids). **Do not read them while tuning prompts, grammar or parsers.** Run them only to measure a finished candidate, and report the results separately. |
| `corpus/multi_dev.jsonl` | 23 multi-turn scenarios: restart, cross-chat, correction, deletion, cancellation, permission denial, model unavailable. |
| `corpus/FROZEN.json` | SHA-256 of each file, plus a per-case hash for every held-out case. |

Changing any corpus file makes validation fail until someone runs `--freeze` again. Re-freezing is a reviewed
decision. It must be recorded in the stage report with the reason. Never edit held-out cases to make them pass.

## Fixed context

Unless a case sets `now`, it runs at `2026-10-19T07:41` (Monday) in `Asia/Kolkata`. All times use local wall-clock
`YYYY-MM-DDTHH:MM`. Corpus runs use an injected fixed clock and a disposable database with a non-delivering scheduler. Calendar expressions must not be tested by shifting every expected timestamp by a constant offset. Real phone alarm delivery is a separate real-clock test. In `setup`, tasks get SQLite ids 1..n in listed order, so `#2` means the second task.

## Case shape

```
{id, split, category, source, origin?, input, now?, setup?, expect, wording?, tags?}
```

- `category`: scheduling | updates | lists | progress | memory | ambiguity | negation | chat.
- `source`: user_history (verbatim from the user's screenshots, device checklist or the tests built from them) |
  plan_matrix | gap_report | synthetic. Every non-synthetic case cites its `origin`.
- `setup`: `tasks` (`ref, title, due?, done?, awaiting?`), `reminders` (`ref, title, at, task?, kind?`),
  `memories` (`ref, content, category`), `history` (prior messages, `chat`/`role`/`content`/`kind?`),
  `prefs` (`follow_up`, `multiple`), `env` (`model: unavailable`, `notifications: denied`).

### `expect`: state, judged by the database (gating)

- `kind`:
  - `write`: exactly the listed `changes`, and nothing else is written.
  - `clarify`: one question about `clarify.field`; no task, reminder or memory writes. An optional `pending` gives
    the draft that must survive.
  - `answer`: database-derived facts. `answer.include`/`exclude` are refs; `include_text`/`exclude_text` are
    literals.
  - `reply`: conversation only; no writes.
  - `none`: the turn was cancelled before commit.
- `changes[].op`: create_reminder, create_task, create_daily, complete_task, delete_task, edit_task, cancel_reminder,
  save_memory, supersede_memory, delete_memory, set_outcome, set_details.
  - `title_has` and `title_not` are case-insensitive substrings of the stored title.
  - `at` is the exact primary time. `on` is a date only, where any disclosed default time counts.
  - `lead` lists explicitly requested early-alert minutes. Configured default nudges are not listed and are not
    judged here.
  - `cancels_alerts: true` means every future alert linked to the task is disabled.
  - `scheduled: false` means saved but not schedulable, as when permission is denied.
  - `$last` (multi-turn only) refers to the entity written in the previous turn.
- `also_ok`: alternative acceptable expectations. Use these where the plan permits either acting with a disclosed
  default or asking one targeted question.
- `forbid`: ops that must not happen, even inside an alternative.
- `about`: refs that a reply must be grounded in, with no fabricated facts about other items.
- `reply_has`: facts that must appear in the reply, such as a computed number or a truthful status word. These are
  facts, not wording.

### `wording`: preferred phrasing (not gating)

`prefer` and `avoid` feed the separate response rubric (relevance, groundedness, concision, repetition, tone).
Never score them as state accuracy.

## Measuring

Report each run against the build revision (`buildRevision`), the model id and SHA-256, and
`promptContractVersion:promptFingerprint` (see `lib/assistant/engine.dart`). Report results per split, category
and route (`lastDiagnostics['route']`). Report assisted end-to-end results separately from model-only plan
accuracy. Report a case as failed, or as not run; never estimate a result.


## Executable reference checks

`flutter test test/reliability_corpus_test.dart --dart-define=CORENYTH_EVAL=true`
records all single development cases through real production SQLite and a non-delivering scheduler, with the model unavailable.
`python3 -I eval/score.py eval/results/rules-dev.json` scores the recorded state.
The runner is skipped during ordinary unit tests. Set `TZ=Asia/Kolkata` on hosts outside that timezone.

Native reference: build the pinned llama.cpp sources for the host CPU, then compile `eval/native_host.cpp` against those libraries to `/tmp/corenyth-native-host`. Place the verified local model at `/tmp/corenyth-Qwen3-0.6B-Q4_0.gguf`. Add `--dart-define=CORENYTH_EVAL_NATIVE=true` to the same test command. This evaluates actual model output with the production prompts, tokenizer settings, grammar and greedy sampler. It does not use a chat CLI template around the already rendered ChatML. Each invocation loads a fresh context, so its duration is not warm phone latency.

Run `python3 -I eval/source_manifest.py` before recording a candidate. The result includes all current source files, including uncommitted new files; the runner saves its content identity. Model checksum and backend revision are in `results/native-identity.json`.

After development tuning finishes, add `--dart-define=CORENYTH_EVAL_SPLIT=heldout`. Do not tune on its results. Score its output separately. `score.py` reports **incomplete**, never pass, for unimplemented checks/rubrics; its pass count is not a complete product acceptance rate. It does not yet run the multi-turn JSONL corpus. Multi-turn behavior is covered separately by the named regression tests; never count those as executed corpus cases.
