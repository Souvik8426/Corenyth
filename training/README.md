# Fine-tuning Qwen3-0.6B for Corenyth

LoRA fine-tune of the default model so the model (not code workarounds) reads
intents, writes the personality-voiced `reply`, and reads the user's mood for
the mascot. Every prompt is rendered byte for byte like the app's:

- **plan contract** (`Prompt._renderPlan`): `{"emotion":{...},"intent":...,"reply":...}`
- **reply contract** (`Prompt._renderReply`): `{"emotion":{...},"type":"respond","text":...}`, with
  the `Facts:` goal lines the app sends (small talk, and the history-free mood-reading job).

The mood is the user's, never the personality's ("never infer emotion from the
configured reply tone"). It is one of `calm | happy | excited | supportive | concerned |
curious | unknown`, with intensity and confidence to two decimals (the grammar's shape).

## Keeping prompts identical to the app

```sh
flutter test training/export_prompts_test.dart --dart-define=EXPORT_PATH=/abs/prompt_export.json
python3 -I training/make_app_prompts.py /abs/prompt_export.json training/app_prompts.py
python3 -I training/build_dataset.py - /tmp/out --check /abs/prompt_export.json
```

`app_prompts.py` is generated; `--check` fails when the renderer differs from the
Dart prompts (plan with and without a tone, reply with and without history).

## Data

| Part | Script | Source |
|---|---|---|
| Plan rows (intents, `#id`, times, replies) | `build_dataset.py` | Amazon MASSIVE en-US (CC BY 4.0) + generated cases, replies from `reply_banks.json` |
| Reply rows (multi-turn small talk, one row per assistant turn) | `build_chat_rows.py` | the 4,000-record personality export (950 + 50 per personality), turns labelled with a mood |
| Mood rows (emotional messages as plan rows) | `build_chat_rows.py` | GoEmotions (Apache-2.0) mapped by `goemotions_mood.py`, plus generated excited/concerned messages |

- **Personalities**: loving, professional, caring, friendly (`lib/assistant/personalities.dart`). Old
  profile tones (calm, mature, cheerful, playful) appear in about 1 of 9 prompts, as the app maps them.
- **Reply banks** (`reply_banks.json`): per personality, written to each voice and screened by the
  app's own reply filters (`safe_follow_up`, `safe_chat`, at most 12 words, no dash joins).
- **Mood labels** come from a rubric reading (the app's `emotionGuide`) by a second model. Mood rows
  are kept only when that reading agrees with GoEmotions' mapped mood (or the intended mood for
  generated messages). About half of GoEmotions rows pass; generated ones pass about 97%.
- The personality export is not quality certified (formatting checked, editorial review pending).

## Training: `colab_cells.py`

Colab T4, Unsloth, LoRA r=32 on all projections, lr 2e-4, loss on the completion only,
`MAX_LEN` 2048 (the plan prompt alone is about 1.2k tokens), then merge and export Q4_0 GGUF.
Upload `corenyth_training_bundle.zip` (made by `make_bundle.py`) to `/content`, then run the cells.

`generate_teacher.py` (teacher-labelled extra rows through Ollama) predates the mood envelope and is
not part of this run.

## Using the model

A retrained file has a new size and hash. Update `corenythModel` in
`lib/services/model_status.dart` (size, SHA-256) before the app will load it, then push:

```sh
adb push Qwen3-0.6B.Q4_0.gguf /sdcard/Documents/localmodels/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf
```

## Known gaps

- Validation shares templates with training for the plan rows; judge on the phone script.
- Intensity and confidence come from the labelling model; confidence is a constant 0.80, not calibrated.
- GoEmotions is Reddit text, not task chat; the generated messages add the assistant setting.
