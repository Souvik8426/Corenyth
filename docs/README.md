# Corenyth Docs

How the offline assistant works, one topic per file.

| Doc | Covers |
|---|---|
| [architecture.md](architecture.md) | Components, layers, and where each lives in the repo |
| [request-flow.md](request-flow.md) | What happens from the moment a user sends a message |
| [llm-engine.md](llm-engine.md) | llama.cpp native build, JNI bridge, prompt, grammar, fallback |
| [tools-and-validation.md](tools-and-validation.md) | Tool schemas, validation rules, and the tool executor |
| [data-model.md](data-model.md) | SQLite schema, repositories, memory search |
| [model-install.md](model-install.md) | Getting `Qwen3-0.6B-Q4_0.gguf` onto the phone and loading it |
| [android-platform.md](android-platform.md) | Permissions, widget, voice activity, reminders, boot |
| [build-and-run.md](build-and-run.md) | Setup, build, test, run, debug logs |
| [known-gaps.md](known-gaps.md) | What is not built yet, and known rough edges |

Start with [architecture.md](architecture.md) if you are new to the project.
