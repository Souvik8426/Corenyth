# Archive

Historical records. Nothing here is maintained or describes the current code with authority; the docs under
`architecture/`, `guides/` and `development/` do. Files are kept unchanged (apart from their location) so the
evidence trail stays intact.

## plans/

| Path | What it is |
|---|---|
| [corenyth-follow-through-plan.md](plans/corenyth-follow-through-plan.md) | Six-step follow-through implementation plan (15 Oct 2026), with worker ownership. Formerly at the repo root. |
| [assistant-reliability-plan.md](plans/assistant-reliability-plan.md) | Reliability repair plan P0 to P5 with its self-answered requirements review, prefixed by the final outcome (acceptance not achieved). |
| [reliability-workflow/](plans/reliability-workflow/) | Serial stage-by-stage agent workflow that executed the reliability plan. |

### reliability-workflow/

| Files | What they are |
|---|---|
| `README.md`, `BRIEF.md`, `PARENT-REVIEW.md` | How the workflow ran: stage order, shared worker brief, acceptance checklist |
| `HANDOFF.md` | Final handoff. P5 verification finished, acceptance rejected, no worker running. |
| `P0-*` to `P5-*` `prompt.md`, `report.md`, `parent-review*.md`, `review.json` | Per-stage prompts, worker reports and reviews. `P5-report.md` is the final verification report. |
| `P2-complete-spec.md`, `P2-interruption.*` | Full P2 spec and a record of an interrupted run |
| `P*-*.txt` | Captured analyzer, test and build output used as evidence |
| `state.json`, `run_stage.py`, `.workflow.lock`, `.gitignore` | Workflow runner state and script. The run is finished. `state.json` and the stage prompts still contain absolute and `docs/plans/...` paths from before the move, and point at a temporary run directory that may no longer exist. |
| `agy-temporary-rules.json`, `device-inventory.json`, `baseline-location.txt`, `sqlite3-host-reference.md` | Supporting records: temporary tool permission rules (removed), device inventory, baseline location, host SQLite hook notes |
