# Serial implementation workflow

Source plan: ../assistant-reliability-plan.md
User authorization: 19 October 2026, execute stages through Claude Code in sequence.

P0 baseline → P1 time → P2 coordinator/receipts → P3 context/memory → P4 response/health → P5 qualification.

Each stage has its own complete prompt, a fresh Claude context, completed-output artifact, and a review report. `run_stage.py Pn` refuses to run if the predecessor is not accepted. It never auto-accepts or starts another stage. Codex reviews actual diffs, meaningful tests and limitations before updating state. Failed reviews return to the same stage. Device-only evidence may remain explicitly pending; failed required software checks block advancement.

Workers leave changes uncommitted. State and stage reports live here; transient detailed output and manifest live in the unique operating-system temporary directory recorded in state.json. This workflow is restartable from evidence but is not an unattended background service. If that temporary directory is removed, preserve reports and create a new attempt directory before resuming.

Read BRIEF.md for boundaries. Do not read held-out case contents to tune implementation. Do not count a passing mock engine as real-Qwen accuracy.

User updated routing: remaining stages use agy Gemini 3.8 Flash (High), high effort. Runner defaults to agy. Historical Claude attempts remain preserved.
