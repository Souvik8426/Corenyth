Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P2
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P2 — unify interpretation and execution boundaries (depends P1)

Scope: coordinator/plan/validation/receipt modules extracted from `session.dart`, semantic grammar and prompts, existing tools/repositories where receipts and operation identity require them.

Implement the contracts above for create/update/complete/list/recall first. Inventory existing early/follow-through handlers and migrate each with explicit priority and parity tests. Add progress/outcome/detail support next. Bound model calls; never retry identical greedy output without changing the request or evidence. Measure any repair attempt before enabling it.

Keep current scheduling semantics and cancellation recovery. Add an additive, data-preserving migration only if durable operation identity or typed pending records require one. Test old pending records and existing task/widget consumers.

Gate: each accepted action has one route, validated evidence and one receipt; ambiguous/negated/hypothetical input produces no unintended writes. Retry/crash tests do not duplicate tasks or alarm intents. Existing follow-through acceptance cases pass.


Additional stage requirements:
This is the major architectural stage. Deliver real shared contracts and coordinator boundaries with all existing routes inventoried/migrated, not decorative unused types. Include typed execution receipts, retry identity semantics and persistent typed pending interactions where necessary. Preserve existing task and notification behaviors. Explicitly audit writes outside ToolExecutor. Do not defer core requirements silently.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P2-DONE.json and the repository stage report when finished. Work on this stage only and stop.

Mandatory rollout/rollback contract: introduce an internal interpreter switch, retain the prior route until parity/device gates pass, and provide read-only old/new comparisons on synthetic fixtures. Exactly one executor writes. Include this in tests and the handoff. Do not remove the old interpretation path prematurely.

Baseline obligation from P0 parent review: test/proactive_session_test.dart has a failing “questions, negations and hypotheticals never become updates or writes” test at c1d1ada. Read its actual assertion and investigate against the product's no-unintended-write requirement. The failure currently concerns reply-prompt calls, not proven state mutation. Preserve or strengthen no-write assertions; do not silence the test. Correct a stale implementation-coupled expectation only with documented evidence and meaningful behavior coverage. Run the complete suite after architectural integration and classify remaining UI-owned failure separately.

Prompt/validation audit: distinguish polite action requests (“Can you remind me…?”) from informational questions (“How do reminders work?”), hypothetical suggestions and actual negation. The old planSystem's “only asking” negation instruction is ambiguous; the shared plan contract and tests must represent authorization clearly. Do not use question marks alone as a blanket no-action rule for explicit polite requests, or rely on a model's confidence.

CONTINUATION AFTER QUOTA INTERRUPTION: Read P2-interruption.md and P2-interrupted-analyze.txt / P2-interrupted-tests.txt. The previous Claude session hit its account session limit, not a code completion; no P2 DONE/report exists. Existing partial P2 code compiles, but no P2-specific tests were written. Complete the full P2 contract and meaningful failure/retry/migration/authorization/route-comparison tests, preserve P1's 79 temporal checks, resolve the proactive-session baseline obligation, and verify v7 data preservation before updating the schema-version assertion. Do not treat partial code as accepted. Finish P2 and STOP with fresh DONE/report for parent review.

IMPLEMENTER SWITCH AUTHORIZED BY USER: continue P2 with agy Gemini 3.8 Flash (High), high effort. Do not wait for Claude quota or attempt to invoke Claude. Read the partial code and Claude interruption handoff, verify all contracts and write missing meaningful tests. Capture results in this new attempt directory, produce P2-report.md and P2-DONE.json, then STOP. Codex reviews before P3.

AGY CONTINUATION: the prior agy attempt wrote test/p2_architecture_test.dart, updated migration assertions and strengthened proactive question tests, but ended without report/DONE after an unnecessary attempt to read an old P1 DONE artifact outside its assigned workspace. Do not retry that denied file read, do not inspect other attempts or copy another stage's DONE file. The accepted predecessor reports are in this repository; your DONE schema is explicitly described in BRIEF.md. Use only repo files and THIS fresh assigned attempt directory for output. Complete checks, fix genuine failures without weakening behavior, write P2-report.md and the requested P2-DONE.json, and STOP. Run tests synchronously where possible or wait for actual completion; do not return merely saying a background test was launched.

PARENT REVIEW BLOCKERS BEFORE FINALIZING:
1. Parent ran the full suite with --dart-define=CORENYTH_INTERPRETER=unified: 380 pass, 2 fail (P2-parent-unified-tests.txt). Sidebar is the known P4 item, but turn_diagnostics_test's hardcoded v1 fingerprint fails for legitimate v2; test both interpreter contracts explicitly rather than weakening identity checks.
2. CRITICAL production wiring: AppServices.newSession currently does NOT pass operations: OperationJournal(db). Architecture tests manually inject it, so production journaling is disabled. Parent added test/p2_composition_regression_test.dart; its failure is captured in P2-composition-red.txt. Wire the production factory and prove actual session journal/replay across service/session reconstruction. Review startup crash reconciliation; do not blindly abandon operations still active in another engine. Document/test the chosen recovery semantics.
3. Complete report/DONE. A prior denied read was an unnecessary old P1 DONE file; do not retry that target. All prerequisite accepted reports and parent test results are under docs/plans/reliability-workflow in the repo. You have no need to inspect another attempt directory. Use this fresh assigned output path only.
