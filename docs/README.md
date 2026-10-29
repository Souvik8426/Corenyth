# Corenyth documentation

How the offline assistant is built, how to run it, and where it stands. New here? Read
[architecture/overview.md](architecture/overview.md) first, then [guides/build-and-run.md](guides/build-and-run.md).

For the current quality picture, start with [development/reliability-status.md](development/reliability-status.md).
Implemented features are not a claim of general language accuracy.

## Layout

```
docs/
├── README.md              this index
├── architecture/          how the app works
├── guides/                set up, build, install the model
├── development/           status, known gaps, on-device validation
├── decisions/             product decisions and what was delivered against them
└── archive/               historical planning and agent workflow records
```

## architecture/

| Doc | Covers |
|---|---|
| [overview.md](architecture/overview.md) | Layers, components and where each lives in the repo. The "model interprets, code acts" rule. |
| [request-flow.md](architecture/request-flow.md) | What happens from the moment a user sends a message |
| [llm-engine.md](architecture/llm-engine.md) | llama.cpp native build, JNI bridge, prompt layout, grammar, fallback |
| [tools-and-validation.md](architecture/tools-and-validation.md) | Tool schemas, validation rules and the tool executor |
| [data-model.md](architecture/data-model.md) | SQLite schema and migrations, repositories, memory search |
| [android-platform.md](architecture/android-platform.md) | Permissions, task/companion widgets, assistant prompt panel, reminders, boot recovery |

## guides/

| Doc | Covers |
|---|---|
| [build-and-run.md](guides/build-and-run.md) | Requirements, llama.cpp checkout, test, build, run, debug logs, release verification |
| [model-install.md](guides/model-install.md) | Side-loading and verifying the fine-tuned Qwen3-0.6B (the only allowlisted model) |

## development/

| Doc | Covers |
|---|---|
| [architecture-execution-plan.md](development/architecture-execution-plan.md) | Detailed remaining work: implementation contracts, dependencies, tests and acceptance gates |
| [architecture-next-steps.md](development/architecture-next-steps.md) | Source-grounded implementation sequence after the Mem0/Hermes study |
| [architecture-study-mem0-hermes.md](development/architecture-study-mem0-hermes.md) | Memory and agent architecture research; proposed gains require validation |
| [architecture-acceptance-report.md](development/architecture-acceptance-report.md) | Live gate status while executing the architecture plan |
| [capability-matrix.md](development/capability-matrix.md) | Supported wording vs stored entities, permissions, receipts and unsupported variants |
| [reliability-status.md](development/reliability-status.md) | Implemented repairs, recorded test and corpus results, open acceptance gates |
| [known-gaps.md](development/known-gaps.md) | What is not built yet, and known rough edges |
| [device-evaluation.md](development/device-evaluation.md) | Checking real model behavior and notification delivery on a phone |
| [performance-validation.md](development/performance-validation.md) | Measuring inference, memory, thermal behavior and alarms on a device |
| [follow-through-device-checklist.md](development/follow-through-device-checklist.md) | Phone scenarios for contextual replies, proactive delivery and recovery |

The evaluation corpus and its runner are documented next to the code in [../eval/README.md](../eval/README.md).
Fine-tuning data, the Colab training cells and the first run's results are in [../training/README.md](../training/README.md).

## decisions/

| Doc | Covers |
|---|---|
| [expectation-gap-report.md](decisions/expectation-gap-report.md) | Product gaps against the reference conversation, and the confirmed follow-through decisions (15 Oct 2026) |
| [follow-through-implementation.md](decisions/follow-through-implementation.md) | What was delivered against those decisions, verification and remaining device checks |

## archive/

Planning documents and agent workflow records produced while the project was built with AI coding tools. Kept for
history and evidence (the P5 verification report is cited by the status docs). Not maintained. See
[archive/README.md](archive/README.md).

## Other docs in the repo

- [`../README.md`](../README.md): project overview.
- [`../eval/README.md`](../eval/README.md): frozen evaluation corpus, scoring and native host reference.
- [`../training/README.md`](../training/README.md): Qwen3-0.6B fine-tune data (MASSIVE + generated) and Colab training.

## Moved paths (19 October 2026)

The docs were reorganized from a flat folder. Older notes, reports and the frozen eval corpus `origin` fields still
cite the old paths. They map as follows:

| Old path | New path |
|---|---|
| `docs/architecture.md` | `docs/architecture/overview.md` |
| `docs/request-flow.md`, `llm-engine.md`, `tools-and-validation.md`, `data-model.md`, `android-platform.md` | `docs/architecture/` (same names) |
| `docs/build-and-run.md`, `model-install.md` | `docs/guides/` |
| `docs/reliability-status.md`, `known-gaps.md`, `device-evaluation.md`, `performance-validation.md`, `follow-through-device-checklist.md` | `docs/development/` |
| `docs/expectation-gap-report.md`, `follow-through-implementation.md` | `docs/decisions/` |
| `docs/plans/` (whole folder) | `docs/archive/plans/` |
| `corenyth-follow-through-plan.md` (repo root) | `docs/archive/plans/corenyth-follow-through-plan.md` |
