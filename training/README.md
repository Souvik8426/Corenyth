# Fine-tuning Qwen3-0.6B for Corenyth plans

LoRA fine-tune of the default model on the app's own plan prompts, so the model
(not code workarounds) reads intents and writes the toned `reply` line.

## Data — `build_dataset.py`

- **Amazon MASSIVE, en-US** (CC BY 4.0; the file the Kaggle mirror
  "MASSIVE - 51 languages" links to) for real phrasing of reminders, calendar,
  lists, small talk and out-of-scope requests, relabelled to Corenyth intents.
  Its `[time]`/`[date]` slots become `when`, event/list slots become `title`.
- **Generated cases** MASSIVE lacks: done/complete, postpone, delete by `#id`,
  time answers to a pending question, "I have a meeting tomorrow" statements,
  hard negatives ("Add a task to X" with X already open is never `complete`).
- **Replies**: five hand-written banks per category, one per profile tone
  (cheerful, playful, calm, mature, professional), all screened by the same
  filters the app applies (`isSafeFollowUp`, `safeReply`, `_groundless`).
- Prompts are rendered byte-for-byte like `Prompt._renderPlan`
  (`--check prompt_export.json` verifies it against strings exported from Dart).

```sh
python3 -I training/build_dataset.py en-US.jsonl OUT_DIR [--check prompt_export.json]
```

The frozen `eval/corpus/single_heldout.jsonl` is not used.

## Training — `colab_cells.py`

Colab, T4 GPU, Unsloth: LoRA r=32 on all projections, 2 epochs, lr 2e-4,
loss on the JSON completion only, then merge and export Q4_0 GGUF.

First run (20 Oct 2026): 4,821 rows, 574 steps, ~31 min, loss 1.25 → 0.11.
Validation (150 of 241 held-back rows, same generator, so optimistic):
intent 85 → 148 / 150, task `#id` 116 → 149 / 150.

## Using the model

Output `Qwen3-0.6B.Q4_0.gguf` (381,566,560 bytes, SHA-256
`77d3f6d469a6d5069a86980ec61f77bd0fb8b937b56d4fac0362659ca6c7b821`) is
the app's only allowlisted model (`corenythModel` in `lib/services/model_status.dart`). Push it as:

```sh
adb push Qwen3-0.6B.Q4_0.gguf /sdcard/Documents/localmodels/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf
```

and reopen the app; it verifies the hash and loads it. A retrained file has a new
size and hash, so update `corenythModel` with each new export.

## Known gaps

- Tone is followed only loosely on the phone: replies come from the right
  category but often another tone's bank. More distinct, larger reply banks
  (and more epochs) are the next step.
- Validation shares templates with training; judge on the phone script.
