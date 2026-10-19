# Parent review and stage advancement

This checklist governs Codex acceptance, not worker self-certification.

1. Confirm process exited and fresh Pn-DONE.json and Pn-report.md exist. Check CLI result for errors and permission denials.
2. Review scoped changes and the stage acceptance criteria. Resolve contradictory evidence rather than accepting the summary.
3. Run required independent checks with no concurrent worker test runner. Existing expected baseline failures may be accepted only in P0 as recorded baseline defects.
4. Record actual results, unresolved issues, and all deferred device checks. Prior-stage device evidence stays pending until P5; no blanket “all passed” claim.
5. Write Pn-review.json containing stage, decision, required_software_checks_passed, evidence (existing repo files), deferred_device_checks. P5 also requires product_device_gate_passed=true.
6. Accept through run_stage.py Pn --accept-review <review file>. Only then launch the next stage. If rejected, write a focused repair prompt and explicitly retry the same stage with fresh evidence. Preserve every attempt.

Read-only independent workflow review found and resolved: missing crash recovery, stale attempt path injection, unchecked acceptance, launch races, conflicting P0 phone scope, missing P2 rollback-switch gate, diagnostic privacy checks, and conflated P5 software/device completion. The runner uses an exclusive lock and atomic state updates; acceptance remains an explicit parent action.

Environment discovered by parent: Flutter 3.47.7 at /Users/kawaiii_neko/development/flutter; connected Android device inventory succeeds. Python's SQLite exposes FTS4, which does not establish that Flutter's separate FFI SQLite does. The actual test runtime must be checked.
