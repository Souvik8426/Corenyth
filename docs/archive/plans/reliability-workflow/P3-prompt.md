Read docs/plans/reliability-workflow/BRIEF.md. Workflow run directory: /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_
Assigned stage: P3
Read accepted predecessor reports in docs/plans/reliability-workflow/ before editing.

### P3 — make global context and memory useful (depends P2 context contract)

Scope: context builder, memory/task/conversation repositories and planner/reply prompt construction.

Retrieve relevant tasks before applying caps; include explicitly referenced older items. Inject relevant durable memories into planning and conversation rather than passing an empty list. Keep mutable task facts sourced from SQLite. Store provenance and define correction behavior: an explicit new preference supersedes its prior value, ambiguous contradictions ask, deleted memories disappear from future context. Exclude temporary plans from durable personal facts.

Persist the interaction type and target for clarification and outcome follow-ups. Cross-chat replies should continue the right open interaction; competing open questions require a short disambiguation.

Gate: cross-chat recall, corrected preference, deletion, older-task reference, competing people and restart tests pass with the real retrieval path. Prompt budget tests retain the current request and required pending fields. A storage-only test cannot close this work package.


Additional stage requirements:
Use actual SQLite retrieval path in integration tests. Include personal memories in both planning and prose prompts, task relevance beyond first ten, correction/deletion, cross-chat/restart ambiguity, prompt budgeting and provenance. Avoid passing all database rows or merely three globally important memories.

Write /var/folders/0y/8bj6ywhx5435lj6bcqbl4_th0000gn/T/wf_corenyth_reliability_rjvflfx_/P3-DONE.json and the repository stage report when finished. Work on this stage only and stop.

Parent acceptance detail: ensure test FakeMemory implementations cannot mask production SQL failures; test database retrieval on a real supported schema/runtime. Exclude the current just-persisted user turn from “earlier context”. New memory correction must not erase unrelated facts sharing vocabulary. A deleted or superseded fact must leave both retrieval and prompt contexts. Preserve contradictory facts from different people as distinct until disambiguated. Use bounded context selection, not a truncated first-ten list.

Verified environment detail from parent: sqlite3-3.7.1's installed doc/hook.md states its bundled binaries enable FTS5 but not FTS4; Python's separate SQLite runtime has FTS4. Do not conflate them. For actual Dart repository tests, read sqlite3-host-reference.md in this repository for the parent-verified host-only hook configuration, preserving Android's sqflite behavior. Do not retry the denied external hook.md read. Avoid modifying dependency cache binaries or faking FTS results. A real retrieval test must execute the production SQL. Document the chosen host capability and keep any build-hook configuration limited to the relevant platform.

Handoff correction: P2-report.md mistakenly calls P3 “semantic grammar alignment.” P3 is the global context/memory stage described above and in the source plan. P2's v2 grammar work is already part of P2; do not replace the memory stage with more grammar-only work. Production AppServices sessions now receive OperationJournal; retain that wiring and restart-time regression coverage.

Scope discipline: use the stage report and relevant source sections rather than browsing other attempt/DONE files. Work only in the repo and the fresh assigned attempt directory; avoid reading denied old P1 artifacts. PATH is supplied: run flutter/dart directly, without exporting PATH. Collect actual completed test results and write the report and DONE before stopping. Do not merely announce background commands.

The parent has summarized the installed SQLite hook docs in sqlite3-host-reference.md inside this repository. Use that reference instead of requesting out-of-workspace ViewFile reads of package-cache docs. Verify capability in the actual Dart runtime. Do not inspect denied old attempt artifacts; current repo reports contain all needed predecessor evidence.

CONTINUE P3: the first attempt ended on an unnecessary external package-doc ViewFile permission denial. Do not retry that denied target. The parent already inspected those docs and supplied the needed facts/configuration in sqlite3-host-reference.md inside this repository BEFORE the denial. Use that in-workspace reference and verify actual runtime capability. Implement the full P3 stage, collect completed test results, write P3-report.md and the assigned P3-DONE.json, then STOP before P4. No export PATH; runner already supplies Flutter.
