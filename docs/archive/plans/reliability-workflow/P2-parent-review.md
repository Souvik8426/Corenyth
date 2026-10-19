# P2 parent acceptance review

Decision: ACCEPT software stage after independent review and bounded repairs. P3 is global context/memory retrieval; P5 device/product qualification remains pending.

Independent evidence on the final P2 tree:
- P2 architecture, real production composition/reconstruction and restart-time boundary tests: 32/32 PASS (P2-parent-final-targeted.txt).
- Legacy full suite: 390 PASS, 1 known baseline sidebar finder failure owned by P4 (P2-accepted-legacy.txt).
- Unified full suite: 390 PASS, same single baseline sidebar failure (P2-accepted-unified.txt).
- Analyzer: PASS, no issues (P2-accepted-analyze.txt). Whitespace PASS.
- Frozen corpus validator: PASS, 136 single-turn including34 held-out,23 multi-turn; held-out text not read for tuning.

Review found and required fixes before acceptance:
1. Production AppServices factory omitted OperationJournal while tests injected it manually. Parent RED test proved this; factory and reconstruction/replay tests now pass.
2. Startup changed executing→committed before a receipt existed; relative-time retry then replanned a different time while keeping the old alarm. Parent RED test proved10:15 confirmation versus10:10 stored alarm. Stored-action recovery now covers both statuses and receipts derive stored reminder time/title.
3. Past/exact-boundary replay now bypasses only fresh-create future-time validation, creates no duplicate rows/alarms and reports “already saved” without inventing delivery. Fresh past creates remain rejected.
4. Unified diagnostics use the v2 fingerprint, not the v1 test assumption. Both contracts have explicit checks.

Inspected shared contracts, route coordination, domain write boundary, stamped operation identity, persisted pending state, dual interpreter switch/comparison and authorization gating. Existing proactive no-write test now verifies state/receipts against hostile proposed actions instead of forbidding harmless reply-model calls.

Worker report corrections: P3 is memory/global context, not further grammar alignment. “112 composition/architecture” describes a combined selection including temporal/diagnostics tests; dedicated P2 acceptance selection independently has32 tests. ONNX is not an implemented runtime in this app. These wording errors do not change verified code behavior.

Known limits: active/recent recovery guards are software-tested; actual multiple Flutter engines/process lifecycle, native model accuracy/performance and phone alarm delivery are NOT certified. P5 must retain those obligations. One pre-existing UI selector failure is explicitly carried to P4, not skipped. Legacy remains available via interpreter switch until product qualification.

agy terminal/file-scope denials in earlier attempts were not counted as completion. Final fresh attempt produced valid report/DONE with no denied_actions; parent checks independently reproduce the reported results. No commits/pushes or phone installation.
