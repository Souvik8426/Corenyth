# Current execution owner
The user superseded external-worker orchestration: Codex finishes directly, serially, without agy/Claude. Earlier instructions below are historical. No external worker remains authorized to edit concurrently.

# Shared implementation brief
You are agy Gemini 3.8 Flash (High), implementing one stage of the Corenyth reliability plan under Codex orchestration.
Read docs/plans/assistant-reliability-plan.md in full and docs/expectation-gap-report.md before acting.
The user explicitly authorized implementation on 19 October 2026. Do not reopen product interviewing. Follow the proposed decisions unless source evidence refutes them; explain deviations in your report.
STRICT SERIAL WORKFLOW: implement ONLY the assigned stage; stop after its report. Never begin the next stage, auto-advance the workflow state, or mark acceptance yourself. Codex independently reviews and accepts stages.
No commits, pushes, stashes, resets, data deletion, phone installation/data access, dependency/toolchain installation, settings changes, permission bypass, or cloud features in the app. Existing unrelated changes must survive. Use existing available tooling; record missing capabilities. Read-only adb inventory is allowed; do not change phone state. Do not spawn additional workers.
Write meaningful failing tests before behavior changes where executable; capture RED then GREEN. If tests cannot run, write them and report NOT RUN with the exact blocker; never report mocked tests as real-model accuracy. No weakening tests just to get green.
Search bounded likely SDK locations for Flutter before declaring it absent. Exactly one test runner at a time. Work within this repository and the assigned run directory. Read source instructions if present.
For every stage produce docs/plans/reliability-workflow/Pn-report.md with: status; scope; files changed; concrete evidence/commands/results; unresolved risks; contract handoff for next stage. Also write RUN/Pn-DONE.json with stage, status (completed|partial|blocked), files, checks, blockers, next_stage_handoff. Final response <=8 lines. No next-stage work.
Report stages with missing device-only evidence as software-complete/device-pending where justified, not fully product-verified. A stage's required automated checks must run before claiming its software gate passed. Do not silently relax the plan's gates.

Verified environment: android/local.properties points to /Users/kawaiii_neko/development/flutter; Flutter 3.47.7 / Dart 3.13.5. Android platform tools: /Users/kawaiii_neko/Library/Android/sdk/platform-tools. A phone is connected (adb inventory succeeded). Use explicit paths or process-local PATH. No tool installation is necessary for Flutter checks.

Ownership: the worker owns only the assigned stage implementation, tests, fixtures and Pn-report.md. Codex owns state.json, runner, BRIEF and stage prompts; do not modify these controls. P0 device build/model evidence that cannot be obtained within read-only inventory is explicitly deferred to P5, with each deferred check listed. Default diagnostics must never include raw personal text; synthetic opt-in fixtures may capture model output for evaluation.

User steering: the rest of the campaign (P2–P5 and repairs) uses agy `gemini-3.8-flash-high` with `--effort high`. Claude history is prior evidence, not a requirement to wait for its quota. Fresh context must inspect the partial P2 diff and interruption report. No acceptance criteria or serial gates are relaxed.

agy terminal permissions: standard task command prefixes are explicitly allowed (pwd, rg, ls, cat, sed, read-only git subcommands, flutter, dart, python3, tail/head/wc/find/mkdir). Prefer single commands with process-local PATH inherited from runner. Use file editing tools or Python for task edits. Commits/pushes/reset/stash remain prohibited. No blanket bypass flag is used.

Terminal environment is already configured by the runner. Run flutter/dart directly or by the allowed absolute SDK path. Do NOT export PATH, prepend PATH=, or invoke unrelated setup commands. If terminal permission blocks a check, record it and use existing parent evidence; never stop merely after launching background tests. Predecessor reports are in this repository; do not inspect denied old attempt files. Finish report/DONE explicitly.
