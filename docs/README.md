# Corenyth Docs

How the offline assistant works, one topic per file.

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | Components, layers, and where each lives in the repo |
| [request-flow.md](request-flow.md) | What happens from the moment a user sends a message |
| [llm-engine.md](llm-engine.md) | llama.cpp native build, JNI bridge, prompt, grammar, fallback |
| [tools-and-validation.md](tools-and-validation.md) | Tool schemas, validation rules, and the tool executor |
| [data-model.md](data-model.md) | SQLite schema, repositories, memory search |
| [model-install.md](model-install.md) | Installing and selecting the allowlisted Qwen3 models |
| [android-platform.md](android-platform.md) | Permissions, widget, voice activity, reminders, boot |
| [build-and-run.md](build-and-run.md) | Setup, build, test, run, debug logs |
| [device-evaluation.md](device-evaluation.md) | Check real model behavior and notification delivery on a phone |
| [performance-validation.md](performance-validation.md) | Measure inference, memory, thermal behavior, and alarms |
| [known-gaps.md](known-gaps.md) | What is not built yet, and known rough edges |

Start with [architecture.md](architecture.md) if you are new to the project.
