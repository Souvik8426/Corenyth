# P1 attempt 1 review — REJECTED

The original 52 targeted tests pass independently. This does not establish the full temporal gate.

Read-only independent source review found partial-match paths. Parent added test/temporal_parent_regression_test.dart and ran it against the completed attempt: 4 pass, 6 fail. Concrete unintended writes:
- model: “remind me in 2 weeks at 5pm to call Mum” saves today at 17:00.
- model: “remind me every 2 hours at 5pm to drink water” creates a one-off at 17:00.
- model: “remind me in 10 minutes on 30 February to call Mum” ignores invalid date and schedules +10 min.
- model and rules: “remind me in 1 hour and 2 hours to call Mum” takes only first duration; rules also pollute title.
- model: “remind me tomorrow Friday at 5pm to call Mum” chooses tomorrow despite contradictory named days.

Evidence: P1-parent-probes.txt; source Temporal.read/dateIn/_calendar and session._create. Whole-message unsupported/invalid/conflicting evidence must outrank a model-extracted subset. Do not trust a resolved timestamp when unconsumed temporal constraints remain. Preserve diagnostics and targeted clarification.

Additional source-confirmed gap: Temporal.read captures “half an hour before” as a lead, but _adjust uses only _leadMin from the old restricted _leadRe. Add a RED→GREEN session test; execution must consume the shared resolver's lead, not maintain duplicate restricted interpretation.

P1 is NOT accepted; P2 remains locked. Original worker report/results are preserved in the attempt folder. Repair only these temporal gate failures, retain all previous expectations, and rerun targeted/full checks. Device obligations stay pending P5.
