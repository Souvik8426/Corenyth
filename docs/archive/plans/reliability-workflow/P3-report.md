# P3 — direct implementation review

Software memory gate checked with `test/memory_retrieval_test.dart` and `test/backend_sqlite_test.dart`. Real macOS system SQLite executes the production FTS4 schema, triggers, queries and v2→v8 migration. Android remains on platform sqflite. No fake search result substitutes for retrieval.

Planning and reply prompts now receive relevant active memories. Relevant tasks are ranked before the ten-item cap, including explicit older IDs. Personal statements are excluded from replayed chat history so corrected/deleted facts cannot reappear through that route. The current request is excluded from earlier context. Prompt shrinking retains the request, selected tasks and pending fields.

Memory rows retain operation/source provenance. Corrections supersede matching subject/attribute slots, remove old FTS entries, and preserve other people and unrelated preferences. Writes and supersession share a transaction. Explicit forget requests require an exact fact match; ambiguous deletion directs the user to Memories. Temporary completion/feeling reports are excluded. Persisted task questions and target picks retain the P2 cross-chat/restart tests.

Automated evidence: real repository tests passed; the later full-suite results are authoritative for final candidate. Native model and device evidence belong in P5, not this storage gate.
