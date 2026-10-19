Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P4
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P4 — truthful, concise responses and visible model health (depends P2; integrate P3)

Scope: reply policy, clarification rendering, model status view and service state.

Use receipt-driven confirmations and field-specific questions. Preserve the requested tone without parroting or unsolicited task creation. Complaints inspect the original intent and receipt, acknowledge the actual mistake, and request correction only when necessary. Separate selected model, resident model, and the route used for the last turn. Show an actionable failure reason in model details; routine chat remains plain language.

Gate: narrow-screen checks plus response rubric on real outputs. The loaded-model banner cannot imply that every answer used Qwen. Load failure, parser rejection and notification failure yield distinct, accurate messages.


Additional stage requirements:
Receipt-driven factual confirmations, short field-specific clarification, complaint correction without duplicate writes, selected/resident/last-turn route model health. Verify narrow displays and accessibility. Ground claims in actual committed state and scheduler outcome.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P4-DONE.json and the repository stage report when finished. Work on this stage only and stop.

Parent acceptance detail: do not stream an unvalidated tool success claim. A cancelled generation cannot execute delayed writes or append tokens to a later turn. An inability to parse the user's supplied time must never become “you did not supply a time”. Unsupported fields get one targeted clarification preserving the rest of the plan. Actual last-turn engine and reply source differ from selected/resident model state.

Baseline obligation from P0 parent review: test/assistant_home_test.dart's initial-chat workflow fails on c1d1ada because its ChatSidebar ListTile finder matches multiple rows. Fix the selector to identify the intended chat and continue testing actual switching/history/deletion; do not remove the workflow or weaken its result assertions. By P4 the full software suite must be green, including earlier-stage obligations.

Privacy check inherited from the source plan: default diagnostic/error logs must not include raw request, reply, memory or SQL argument contents. Audit new exception debugPrint paths as part of response/health reporting. Do not add user-facing implementation jargon; keep detailed codes in diagnostics/details.
