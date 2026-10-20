# Third-party notices

Corenyth ships or is built from the following third-party work.

## llama.cpp

Native inference engine compiled into the APK (`android/app/src/main/cpp/llama.cpp`, tag b11541).
MIT License, Copyright (c) 2023-2026 The ggml authors.
Full text: <https://github.com/ggml-org/llama.cpp/blob/master/LICENSE>.

## Qwen3-0.6B (base model)

`Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf` is a modified version of Qwen3-0.6B by the Qwen team, Alibaba Cloud:
LoRA fine-tuned on Corenyth plan prompts, merged and quantized to Q4_0 (see `training/README.md`).
Apache License, Version 2.0: <https://www.apache.org/licenses/LICENSE-2.0>.
Original model: <https://huggingface.co/Qwen/Qwen3-0.6B>.

## Amazon MASSIVE (training data)

The fine-tune uses filtered, relabelled en-US utterances from MASSIVE (FitzGerald et al., 2022),
Copyright Amazon.com, Inc. CC BY 4.0: <https://creativecommons.org/licenses/by/4.0/>.
Source: <https://github.com/alexa/massive>. Replies were written separately.

## Plus Jakarta Sans

Font by Tokotype, SIL Open Font License 1.1 (`assets/fonts/OFL.txt`).
