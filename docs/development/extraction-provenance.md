# Durable extraction provenance (schema v13)

Extraction remains disabled. This change supplies local storage primitives only;
it does not opt anyone in, schedule model work, or change the precision gate.

New foreground turns use `OperationJournal.beginTurn` to insert their user
conversation and uniquely linked operation in one storage transaction. The
source must be a user row in the operation's chat. SQLite constraints verify
that relationship; retries use the durable ID rather than matching text or
choosing the newest row. Existing operations keep a null source; migration
never reconstructs historical relationships.

`MemoryRepo.saveLinked` verifies the identity again inside its transaction.
An actual add, duplicate bump, or correction writes a `memory_write_sources`
marker in that same transaction. Failure, including instruction rejection or a
marker insertion failure, writes no marker. The table contains only the source
message ID: no source or memory text, hash, timestamp, or retained memory ID.
Memory edit, superseding, expiry, rejection and purge cannot remove proof.
Deleting the source cascades the marker and clears the journal's source link.

Memory replay uses that marker, including after purge; matching active memory,
`memories.op_id`, timestamps and intended actions are never proof. A linked
replay without a marker may execute the original journaled memory action.
Interrupted unlinked legacy memory actions are withheld and reported as
`memory_recovery_unresolved` receipts / `recovery_unresolved` journal status.
Independently validated task/reminder actions still recover. The unresolved
notice is saved with their checkpoint so a crash cannot hide it on replay.
Completed legacy receipts remain final; failed independent actions remain
retryable. No historical source linkage is inferred.

`ExtractionRepo.skipIfMemoryWritten(chatId, messageId,
expectedLastMessageId: ...)` checks consent, the captured watermark, ascending
user-source order, and verified proof inside one storage transaction. It
returns `skipped` or `notProvenOrStale`; refusal changes nothing. Callers must
use this atomic method for write-based skips, never a marker read followed by
`advance`. `advance` remains for independently validated skips and valid
`remember:false`. Suggestion publication rejects an already proven source.
Opt-out revokes reads and publication; explicit re-opt-in establishes a latest
message baseline. Failed operations also roll back through savepoints when an
outer transaction catches their errors.

Backups (including pre-import recovery copies) omit source links, markers and
extraction state. Operations retain their existing portable format. Import
therefore restores operations as unlinked legacy records, clears local proof
and consent through source/chat deletion, and requires a new explicit baseline.
A backup is never evidence that a particular imported message wrote memory.
The existing backup and memory-erasure privacy policies continue to apply.

Host coverage lives in `test/extraction_provenance_test.dart`, alongside the
existing storage, replay, expiry, instruction-rejection and backup suites.
