Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P1
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P1 — repair temporal understanding as one complete slice (depends P0)

Scope: new focused temporal module; `rule_engine.dart`, `semantic.dart`, `session.dart`; parser and session regression tests.

Introduce the shared temporal type and capture time once per submitted turn. Handle natural duration forms, short units, word numbers and fillers without corrupting titles. Distinguish “in”, event-relative “within”, deadline “within/by”, “before”, recurrence and event end. Preserve existing supported calendar forms and explicit disclosed defaults. Detect contradictions rather than picking the first timestamp.

Route both model extraction and deterministic fallback through the same resolver. Preserve usable fields when asking for one missing or conflicting value. Do not add a second independent date parser.

Gate: the exact screenshot request creates one meeting reminder at submission + 10 minutes, title without temporal filler, and a concise confirmation; works with valid Qwen extraction and with Qwen unavailable. No broad date-help message. Boundary/negation/conflict tests pass. Optional meeting details never block creation.


Additional stage requirements:
Preserve plan semantics: no global within->in replacement; distinguish event start, alert time, deadline, event end and recurrence. Capture clock once per turn including asynchronous inference. Test exact screenshot, word order, negation, conflicting timestamps, lead times and title cleanliness across model/fallback paths.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P1-DONE.json and the repository stage report when finished. Work on this stage only and stop.

Parent acceptance detail: test positive scheduling and adversarial variants end to end through AssistantSession (a valid scripted semantic extraction AND a model-unavailable session), asserting actual repository state and concise reply. Check duration word order and fillers, “after 10 min”, meeting start versus “5 minutes before”, deadline-only statements, tentative statements, negation, conflicting times, cancellation, and asynchronous model delay. Do not read held-out corpus text. If a case belongs to a later stage, identify it explicitly in the handoff; the screenshot slice and its basic safety cases cannot be deferred.

P0 parent verified Flutter analyzer and debug build PASS; screenshot tests RED as expected. Read P0-parent-review.md. The full suite's two unrelated failures reproduce on c1d1ada and are recorded for later stages. Flutter is now on your process PATH and shell execution is allowed for authorized work, without a permission-bypass flag. Run the RED screenshot checks before implementation. Preserve original regression expectations.

REPAIR ATTEMPT: P1's first attempt is REJECTED. Read P1-parent-review-attempt1.md and P1-parent-probes.txt before coding. Parent's test/temporal_parent_regression_test.dart currently has 6 failures out of 10, all described there. Preserve those tests and get them GREEN along with original temporal/screenshot tests. Whole-message unsupported recurrence, unsupported units, invalid dates and contradictory days must block any valid model-substring schedule. The resolver must never silently consume only the first of two same-rank duration pieces. Also add and run a RED→GREEN end-to-end case for “remind me about the meeting in 2 hours half an hour before”: the shared resolver recognizes a 30min lead but execution currently ignores it. Remove/bypass duplicate restricted lead interpretation using the shared contract, preserving established behavior. Repair within P1 only, rerun analyzer/full suite, update P1 report with exact attempt evidence, write fresh DONE to this attempt directory, then STOP. Do not claim the parent blockers belong to P2/P4.
