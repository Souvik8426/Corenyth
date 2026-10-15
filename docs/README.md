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
| [expectation-gap-report.md](expectation-gap-report.md) | Product gaps against the Grokbot reference and confirmed follow-through decisions |
| [follow-through-implementation.md](follow-through-implementation.md) | Delivered behavior, completed steps, verification and remaining device checks |
| [../corenyth-follow-through-plan.md](../corenyth-follow-through-plan.md) | Implementation steps, dependencies, worker ownership, and progress |
| [follow-through-device-checklist.md](follow-through-device-checklist.md) | Phone scenarios for contextual replies, proactive delivery, and recovery |

Start with [architecture.md](architecture.md) if you are new to the project.
