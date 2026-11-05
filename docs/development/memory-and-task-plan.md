# Memory and Task Handling Plan (after the Mem0/Hermes review)

Status: **proposal, nothing implemented.** Written 30 October 2026 against commit `c6492e2` (branch `beta_version`),
default model `Corenyth-Qwen3-0.6B-mood-Q4_0.gguf` (sha256 `f2086705f885560e76ceb8e48b25bc3a07fad3f0f429f5202efd6dd8bfca69ee`).
Every file and line reference below was checked against that commit.

References: the external review (30 Oct), [architecture-study-mem0-hermes.md](architecture-study-mem0-hermes.md),
Mem0 source (`~/Downloads/mem0-main`), Hermes Agent source (`~/Downloads/hermes-agent-main`).

**Contents**
1. Verdict on the review
2. Additional findings
3. What to take from Mem0 and Hermes
4. Ground rules for every task
5. Phase 0: correctness and the mood job
5B. Phase 0B: messages with several tasks (screenshots, 30 Oct)
6. Phase 1: memory that lasts
7. Phase 2: retrieval at scale
8. Phase 3: model scheduling and speed
9. Phase 4: reminders and background work
10. Phase 5: evidence and documentation
11. Phase 6: splitting `session.dart`
12. Order, sizes and suggested models
13. Decisions for you

---

## 1. Verdict on the review

All four findings and the documentation points hold. Finding 2 is worse than the review describes (see N1).

| Review finding | Holds | Evidence |
|---|---|---|
| 1. "forget …" can delete the wrong memory | Yes | [session.dart:762-773](../../lib/assistant/session.dart): with no exact match, a single OR-prefix FTS hit is deleted and labelled `exact_memory`. |
| 2. Optional mood saves per chunk; diagnostics unguarded | Yes | [session.dart:673-706](../../lib/assistant/session.dart): no accepted flag (the foreground path has one, `_emitMood` line 1664); diagnostics written without an epoch check; `mood = emitted` unconditionally. |
| 3. Temporal fields never written | Yes | [repos.dart:1195-1261](../../lib/data/repos.dart): `add` writes none of `observed_at_utc`, `observation_offset_min`, `fact_date`. |
| 4. Retrieval unbounded before ranking | Yes | [repos.dart:1284-1306](../../lib/data/repos.dart) loads every FTS match; `important()` (1319) loads every active row. |
| Documentation contradictions | Yes | [known-gaps.md:48](known-gaps.md) and line 74 are stale; [architecture-acceptance-report.md](architecture-acceptance-report.md) lines 3, 10, 14, 16, 51 conflict. |

---

## 2. Additional findings

**N1. The optional mood job generates a full discarded reply and holds the model.**
`_runOptionalMood` sends `PromptKind.reply` (cap 132 tokens, [engine.dart:570](../../lib/assistant/engine.dart)) and runs it to the end, but uses only the envelope. The native worker is one thread ([LlamaBridge.kt:30](../../android/app/src/main/kotlin/com/corenyth/assistant/LlamaBridge.kt)). A new turn bumps `_generationEpoch` ([session.dart:404](../../lib/assistant/session.dart)) but never cancels the native job (`engine.cancel()` is only in `close()`, line 3229). A chat message right after a rule-handled one queues behind roughly 10 s of wasted decode.

**N2. Prompt-kind switches throw away the KV cache.**
Native reuse is "longest common token prefix" on one sequence ([llama_jni.cpp:169-177](../../android/app/src/main/cpp/llama_jni.cpp)). The plan and reply prompts differ from their first system token ([engine.dart:263](../../lib/assistant/engine.dart) vs 292). Today a rule turn costs plan → reply(mood) → plan: two full re-prefills. The reply path also puts per-message memories in the system block ([session.dart:1729-1731](../../lib/assistant/session.dart)), so reply → reply loses the cache too. (The plan path already puts memories in the user turn, line 2157.)

**N3. Cancelling a request wipes the whole KV cache.**
Any error, including `llama_cancelled`, calls `reset_cache()` ([llama_jni.cpp:224-228](../../android/app/src/main/cpp/llama_jni.cpp)). Cancelling the mood job naively (to fix N1) would make the next foreground turn fully cold. Tokens decoded before the cancel are valid (`g_cached` is updated only after each successful decode), so only an abort during prompt decode needs a reset. A related edge: stale cells are removed only `if (reuse < g_cached.size())` (line 174). A token whose single-token decode was aborted could leave a cell at position `g_cached.size()`.

**N4. Deleting a memory is permanent and untraced.**
`MemoryRepo.delete` hard-deletes ([repos.dart:1309-1312](../../lib/data/repos.dart)), and there is no history table. Mem0 logs every change (`mem0/memory/storage.py`, `history` table); the Hermes curator "never delete[s], only archive[s]" (`agent/curator.py` header).

**N5. `delete_memory` with `query` deletes every search hit.**
[tools.dart:599-605](../../lib/assistant/tools.dart) deletes all results of `memory.search(query)`. The model can't reach it today, because `delete_memory` is not in `toolSchemas`, so the tool grammar cannot emit it. It is still a loaded gun for any future caller.

**N6. Memory writes scan the whole table.**
`save_memory` recovery checks `memory.all()` ([tools.dart:563](../../lib/assistant/tools.dart)); the `replaces` logic loads `memory.all()` and supersedes outside the add transaction (lines 576-591).

**N7. Search writes on every read.** One `UPDATE` per returned row ([repos.dart:1302-1305](../../lib/data/repos.dart)).

**N8. Model memory extraction exists but is unused.** `PromptKind.memory` / `memorySystem` are referenced only inside engine.dart. Capture is regex-only (`_memoryCandidate`, [session.dart:3161](../../lib/assistant/session.dart)), so incidental facts ("my daughter Sara loves painting, any classes?") are never kept.

**N9. Memories are probably never in Google's Auto Backup.**
The manifest sets no `allowBackup` or backup rules ([AndroidManifest.xml:8](../../android/app/src/main/AndroidManifest.xml)), so Auto Backup includes `files/`, which holds the 381 MB model (`files/models`, [MainActivity.kt:23](../../android/app/src/main/kotlin/com/corenyth/assistant/MainActivity.kt)). Auto Backup skips an app whose data exceeds its 25 MB quota, so the database is most likely never backed up to the cloud. The in-app backup file (`BackupService`) is the only path today.

**N10. Backups would drop the temporal fields.** The backup format carries `status`/`superseded_by` but not the three temporal columns ([backup_format.dart:148-162](../../lib/services/backup/backup_format.dart)). `_checkMemory` (line 274) also rejects any status other than `active`/`superseded`.

**N11. Missed reminders: smaller gap than first stated.** A catch-up already exists: `catchUp()` files the latest missed check-in per task from the last 12 hours, once per occurrence key, silently ([proactive.dart:243-283](../../lib/services/proactive.dart)), on startup, resume, boot and time-zone change. The real gaps: anything missed by more than 12 hours vanishes with no record, and filed catch-ups raise no notification.

**N13. A message with several tasks fails on both models.** Full diagnosis and fix in section 5B.

**N12. Reuse is already logged.** Native logs `prompt N tok (R reused) in X ms; first token Y ms; generated G tok in Z ms` under logcat tag `LlamaBridge` ([llama_jni.cpp:222](../../android/app/src/main/cpp/llama_jni.cpp)). Cache measurement can start without code changes.

---

## 3. What to take from Mem0 and Hermes

| Idea | Source | Adaptation here | Task |
|---|---|---|---|
| Delete only by ID | Mem0 `Memory.delete(memory_id)` | Chat "forget" resolves to one id (exact or slot+value), else asks | 0.1 |
| Unique match or "ambiguous" | Hermes `tools/memory_tool_store.py::_find_unique_match` | Same rule; loose retrieval never deletes | 0.1 |
| Mutation history | Mem0 `storage.py` `history` table | `memory_history`, same transaction | 1.1 |
| Archive, don't delete | Hermes curator invariant | Soft delete, undo, 30-day purge | 1.2 |
| Observation date ≠ current date | Mem0 `ADDITIVE_EXTRACTION_PROMPT` | Stamp facts when said; resolve relative dates deterministically | 1.3 |
| `expiration_date` | Mem0 `_payload_is_expired` | `expires_at` | 1.4 |
| Scan memory text | Hermes `_scan_memory_content`, `[BLOCKED: …]` | Reject instruction-like memories at write time | 1.5 |
| Bounded pool then re-rank | Mem0 `_search_vector_store`: `internal_limit = max(limit*4, 60)`; `utils/scoring.py` sigmoid BM25 | Two-stage FTS ranking | 2.2 |
| Entity boost | Mem0 `_compute_entity_boosts` | `memory_entities` table (only if needed) | 2.4 |
| Frozen memory snapshot | Hermes `tools/memory_tool.py` header (snapshot at session start, prefix cache intact) | Memories only in the user turn | 3.3 |
| Cancellable background review | Hermes `agent/background_review.py` (cancel handshake, 2 s timeout) | Preemptible optional/background model work | 0.3, 3.1 |
| Idle-triggered maintenance | Hermes curator (min idle 2 h) | Idle-gated extraction and purge | 1.2, 4.3 |
| Never drop a slot silently | Hermes `cron/AGENTS.md` | One "while you were away" summary for >12 h misses | 4.1 |
| Failure limit | Hermes kanban `failure_limit` (2) | Block a background job after 2 failures on one input | 3.1 |
| ADD-only model extraction, small integer IDs | Mem0 v3 pipeline ("Your sole operation is ADD"; UUIDs mapped to "0","1"…) | Suggested memories the user approves | 4.3 |

**Not copied:** vector store and embeddings; LLM-decided UPDATE/DELETE; agent loop, subagents, kanban; LLM summarisation of old turns.

---

## 4. Ground rules for every task

- **Branch:** work on `beta_version` or a feature branch off it. You commit; agents never commit.
- **Gates before a task counts as done:** `flutter analyze` with no new errors or warnings (111 infos at baseline), and `flutter test` all passing (538 pass, 3 skipped at baseline), plus the task's own new tests.
- **Device checks (POCO F5, adb id `462a848c`):**
  - Build and install: `flutter build apk --profile`, then `adb -s 462a848c install -r build/app/outputs/flutter-apk/app-profile.apk`.
  - Never uninstall the app or clear its data.
  - Native timings: `adb -s 462a848c logcat -s LlamaBridge`.
- **Schema changes are additive** (repo convention, [db.dart:13](../../lib/data/db.dart)). No table rebuilds of `tasks`: the Android widget reads it ([WidgetTaskService.kt:15](../../android/app/src/main/kotlin/com/corenyth/assistant/WidgetTaskService.kt)).
- **Prompt bytes are a training contract.** Any change to `Prompt.render*` output needs a retrain, plus the parity export in `training/export_prompts_test.dart`. Phases 0–2 change no prompt bytes, except 0.2, which reuses the existing plan layout.
- **Model choice:** each task lists a *suggested* model (section 12). It's advice, not an assignment. Have a different model review the change than the one that wrote it.

---

## 5. Phase 0: correctness and the mood job

### 0.1 Safe "forget" targeting

**Goal:** a "forget …" message deletes a memory only on exact or slot+value evidence. Anything weaker asks which one.

**Files:** [session.dart:751-778](../../lib/assistant/session.dart) (forget branch), [repos.dart](../../lib/data/repos.dart) (new method), [tools.dart:593-607](../../lib/assistant/tools.dart) (executor).

**Steps**
1. In `repos.dart`, add a result type and resolver on `MemoryRepo`:
   ```dart
   enum ForgetEvidence { exact, slot, candidates, none }

   class ForgetMatch {
     final ForgetEvidence evidence;
     final List<Memory> memories; // 1 for exact/slot, 1–3 for candidates, 0 for none
     const ForgetMatch(this.evidence, this.memories);
   }

   /// Which active memory a "forget …" request names. Loose retrieval only
   /// ever yields candidates to ask about, never a deletion target.
   Future<ForgetMatch> matchForForget(String fact);
   ```
   Logic, in order:
   - **Exact:** normalize `fact` the same way `add` does (lowercase, strip trailing `.!?`, collapse spaces), SHA-256 it, and query `status = 'active' AND content_hash = ?` (indexed `memories_status_hash`). Then compare normalized text. One hit → `exact`.
   - **Slot + value:** `extractMemorySlot(fact)`. If non-null, query active rows with that `subject_key`/`attribute_key` (indexed `memories_slot`). Keep a row only if it shares at least one *value term* with `fact`. Value terms are `MemoryRepo.terms(fact)` minus slot vocabulary (`user`, `i`, `my`, `like(s)`, `love(s)`, `prefer(s)`, `hate(s)`, `dislike(s)`, `drink(s)`, `live(s)`, `work(s)`, `as`, `in`). Exactly one → `slot`. This stops "forget that I like coffee" from deleting "User prefers tea", which shares the slot but not the value.
   - **Candidates:** `search(fact, limit: 5)`, keeping rows whose content contains every value term of `fact`. 1–3 → `candidates`. More than 3 → `none` with the "several match" reply.
   - **None** otherwise.
2. Replace session.dart lines 760-778 with:
   - `exact` → `ToolCall('delete_memory', {'id': id})`, `_evidence['target'] = 'exact_memory'`.
   - `slot` → the same call with `_evidence['target'] = 'slot_memory'`.
   - `candidates` → `_setPick(TargetPick(tool: 'delete_memory', args: const {}, ids: [...ids], askedAt: _now()))`, and reply `"Which memory should I forget?\n#41 User drinks coffee every morning\n…"`. The existing `_pickRoute` ([session.dart:1056](../../lib/assistant/session.dart)) parses "#41" or "41". It returns `_withId(pick, 41, 'pick')` → `ToolCall('delete_memory', {'id': 41})` with evidence `pick`; `_withId` only touches tasks for `keep_time`/`shift`, which are absent.
   - `none` → keep today's two replies (no match / several match).
3. In `tools.dart` `delete_memory`: delete the `query` branch (N5). Return `ToolError('delete_memory needs an id')` when `id` is not an int.

**Tests** (new `test/memory_forget_test.dart`, sqflite FFI like `test/p3_p6_architecture_test.dart`):

| # | Saved memories | Message(s) | Expect |
|---|---|---|---|
| F1 | "User likes green tea" | "forget that I like green tea" | deleted; evidence `exact_memory` |
| F2 | "User drinks coffee every morning" | "forget that I wake up every morning" | nothing deleted; reply lists `#id`; a pick is stored |
| F3 | (F2 state) | "#\<id\>" | deleted; evidence `pick` |
| F4 | "User prefers black coffee" | "forget that I like coffee" | deleted; evidence `slot_memory` |
| F5 | "User prefers tea" | "forget that I like coffee" | nothing deleted; "couldn't identify" reply |
| F6 | none | "forget that I like tea" | nothing deleted; "couldn't identify" |
| F7 | 4 memories containing "pune" | "forget that I live in pune" | nothing deleted; "several match" reply |
| F8 | any | "forget it" | not the forget route (pronoun guard unchanged) |
| F9 | executor | `ToolCall('delete_memory', {'query': 'tea'})` | throws `ToolError`; nothing deleted |

Also grep the tests for the old reply strings and the `exact_memory` label, and update them.

**Done:** F1–F9 pass, plus the gates.
**Suggested model:** standard (Claude Sonnet or Codex default). The logic is local and well specified.

### 0.2 Mood job: plan prompt, mood-only grammar, accept once

**Goal:** the optional mood job costs about 25 decode tokens instead of about 60, saves once, and leaves the plan prompt's system block warm for the next turn.

**Key idea:** the plan contract already emits the envelope first. So reuse the **plan prompt layout**, which keeps the system block identical to the next plan turn (KV reuse, N2). Add a grammar that ends after the envelope: llama.cpp's grammar sampler allows only end-of-generation once the grammar is complete, so generation stops by itself. No native change is needed for the stop, and `maxTokens = 32` is the backstop if it doesn't. With greedy decoding, the mood values are the same as the full plan grammar would produce for that prompt (only the token after the closing brace differs).

**Files:** [engine.dart](../../lib/assistant/engine.dart) (Prompt, LlamaChannelEngine), [semantic.dart:161](../../lib/assistant/semantic.dart) (reuse `emotionGrammar`), [session.dart:638-709](../../lib/assistant/session.dart).

**Steps**
1. `Prompt` gains `final bool moodOnly;` (constructor param, default `false`), copied in `_with()` (engine.dart:317).
2. Add `static final moodOnlyGrammar = 'root ::= "{\\"emotion\\":" emotion "}"\n$emotionGrammar';`. In the `grammar` getter (line 110), return it first when `moodOnly`.
3. `LlamaChannelEngine.completeStreaming`: `final maxTokens = p.moodOnly ? 32 : switch (p.kind) {…}` (line 564).
4. `_dispatchOptionalMood` captures immutable inputs at dispatch:
   - `contract` (`_mode == Interpreter.unified ? planContractV2 : promptContractVersion`, as at line 2110)
   - `tone` and `UserProfile`, read once in `_turn` (today they are read twice inside the job)
   - `now`
5. `_runOptionalMood` builds:
   ```dart
   final p = Prompt(PromptKind.plan, text,
       now: now,
       contract: contract,
       tasks: '(none)',          // in-distribution for the plan contract
       tone: tone,
       personalContext: buildPersonalContext(profile, const []),
       moodOnly: true);
   ```
   The system block is byte-identical to the coordinator's plan prompt, which also uses `buildPersonalContext(profile, const [])` (line 2164).
6. Accept once and guard staleness:
   ```dart
   bool stale() => _cancelled || epoch != _generationEpoch || _closeRequested;
   MoodReading? accepted;
   Future<void>? save;
   await engine.completeOptional(p, onRaw: (chunk) {   // completeOptional: task 0.3
     if (accepted != null || stale()) return;
     final reading = planStreamView(chunk).mood;
     if (reading == null) return;
     accepted = reading;
     moodSink?.call(record /* source 'model:mood', generationId '$opId/optional_mood' */);
     save = moods?.save(...).catchError((_) {});
   });
   await save;
   if (stale()) return;
   _diag['mood'] = accepted == null
       ? 'none'
       : '${accepted!.mood?.name ?? 'unknown'}(model:mood)';
   _diag['model_calls'] = '${_budget.plan}p${_budget.reply}r+mood';
   lastDiagnostics = Map.unmodifiable(_diag);
   ```
   Keep the existing `on PlatformException {}` (a preempted job ends silently).
7. Update `_SlowOptionalEngine` in [p3_p6_architecture_test.dart:22-48](../../test/p3_p6_architecture_test.dart): detect `p.moodOnly`, not `p.kind == PromptKind.reply && context contains 'mascot mood'`. Emit a real envelope (`{"emotion":{"mood":"happy","intensity":0.80,"confidence":0.90}}`); today it emits a bare object that `planStreamView` ignores.

**Tests** (extend `p3_p6_architecture_test.dart`):
- M1: the fake streams 5 cumulative chunks that each contain the complete envelope → `MoodRepo.save` runs once, and `rowsForChat` has 1 row with source `model:mood`.
- M2: the optional job is held on a `Completer`; a second `handle()` starts (epoch bump); then release → the first job's diagnostics do not overwrite `lastDiagnostics` of turn 2.
- M3: the fake returns no envelope → `_diag['mood'] == 'none'`, no row saved.
- M4: the prompt sent has `moodOnly == true`, `kind == PromptKind.plan`, and `render()` up to `<|im_end|>` (the system block) equals the coordinator plan prompt's system block for the same profile, tone and contract.
- M5: `Prompt(..., moodOnly: true).grammar` starts with `root ::= "{\"emotion\":" emotion "}"`.

**Device check:**
- Send "remind me to drink water at 5pm" (rule route), then "how's your day?".
- `logcat -s LlamaBridge` should show: the mood request "generated ≤ 32 tok"; the following plan request "(R reused)" with R roughly the size of the system block (not 0).
- Record both lines in the PR.

**Done:** M1–M5 and the gates pass; the device logs as above.
**Suggested model:** high reasoning (Claude Opus or Codex at high effort). It spans the session lifecycle, prompt contracts and an async race.

### 0.3 Foreground preemption and a cache-safe cancel

**Goal:** a new turn never waits behind optional work, and preemption does not cost a cold cache.

**Dart part:** [engine.dart:358-378](../../lib/assistant/engine.dart) (`LlmEngine`), 519-616 (`LlamaChannelEngine`), [session.dart](../../lib/assistant/session.dart) `_turn`.
1. On `LlmEngine` add, with defaults so the 10 test fakes need no change:
   ```dart
   /// Low-priority work (optional mood, later background jobs) that a
   /// foreground request may cancel via [cancelOptional].
   Future<String> completeOptional(Prompt p, {void Function(String raw)? onRaw}) =>
       completeStreaming(p, onRaw: onRaw);

   /// Cancels in-flight or queued [completeOptional] requests only.
   Future<void> cancelOptional() async {}
   ```
2. In `LlamaChannelEngine`, move the body of `completeStreaming` into `_generate(p, {onText, onRaw, bool optional = false})`, keep `final _optional = <int>{}`, and override both methods. `cancelOptional` removes each optional id's listener and invokes `cancel{id}`, the same as `cancel()` but filtered.
3. In `_turn` ([session.dart:477](../../lib/assistant/session.dart)), before `_plan(...)` runs: `await engine.cancelOptional();`. Kotlin handles `cancel` inline (not on the worker), so the cancel lands before the foreground `generate` is queued.

**Native part:** [llama_jni.cpp:169-228](../../android/app/src/main/cpp/llama_jni.cpp).
1. Always trim to the reused prefix before decoding: replace the `if (reuse < g_cached.size())` guard (line 174) with an unconditional `llama_memory_seq_rm(mem, 0, reuse, -1)`, keeping the `reset_cache()` fallback when it returns false. This clears a cell left by an aborted single-token decode.
2. Track `bool prompt_failed`. Set it when the prompt `llama_decode` (line 188) fails. On error, call `reset_cache()` only if `prompt_failed`. A cancel during generation keeps `g_cached` (exactly the decoded tokens).

**Tests**
- Host: a fake engine records calls → `handle()` calls `cancelOptional()` before its first `completeStreaming`. A `completeOptional` started by turn 1 is cancelled when turn 2 starts (the fake's cancel flag is set).
- **Device determinism check (required for the native change):**
  - Scenario A: start a long reply, cancel it after about 10 tokens, then send prompt X.
  - Scenario B: force-stop the app (cold), then send prompt X.
  - Greedy output for X must be byte-identical in A and B, and A's log must show "(R reused)" with R > 0.
- Device latency: rule turn, then a chat turn within 1 s. The chat turn's `total` timing must be within 10% of the same chat turn sent alone.

**Done:** host tests, the determinism check and the latency check pass.
**Suggested model:** high reasoning (Claude Opus or Codex at high effort) for the C++ and JNI part; review it with the other one.

---

## 5B. Phase 0B: messages with several tasks (screenshots, 30 Oct)

### What happened

Two messages on the POCO F5 (Gemma 4 E2B; the same happens with Qwen):

| Screenshot | Message | Reply | Answer source |
|---|---|---|---|
| 1 | A pasted status digest: "Due soon", "Waiting on you" and "Coming up" sections, ~16 bullets | "Okay, your call aditya reminder stays." | Built-in assistant logic |
| 2 | "Add these tasks: **Due soon**" with 6 bullets | "Here is the full picture of what you have going on." | Local model with app checks |

No task was created in either case.

### Reproduction (host, real session code)

Both messages were run through `AssistantSession` with a recording fake engine:
- clock Fri 30 Oct 2026 11:45;
- one existing reminder, "call aditya";
- both interpreters (unified and legacy) gave the same results.

| Case | Route taken | Result |
|---|---|---|
| S1 digest, model available or not | `negated_cancel` (before the model is asked) | "Okay, your call aditya reminder stays." — matches screenshot 1 exactly |
| S2 "Add these tasks", model answers `chat` | `semantic` | "Here is the full picture…" — matches screenshot 2 |
| S2, model answers `list` | `semantic` | the same sentence, and no list is shown |
| S2, model answers the best a one-task plan can (`create_task` "Sachiv V1", tomorrow) | `semantic` | "Okay, I won't save that." — refused |
| S2, no model | `rule_plan` | "I haven't set anything since that sounds undecided…" |
| "add buy milk and call mom tomorrow", no model | `rule_plan` | "I'm not sure what you'd like me to do with that…" |
| "Add these tasks:\n- buy milk\n- call mom tomorrow", no model | `rule_plan` | the same "not sure" reply |

The plan prompt for S2 is about 5.2 KB (~1,450 tokens) of a 2,048-token window with 140 reserved for output. The longer digest in S1 is close to the limit; anything longer is refused as too long.

### Root causes

**R1. One message = one plan, by design, on every model.**
- The plan grammar emits exactly one object with one `intent`, one `title` and one `when` ([semantic.dart:167-216](../../lib/assistant/semantic.dart)).
- `_ModelBudget.maxPlan = 1` allows one plan call per turn ([session.dart:82](../../lib/assistant/session.dart)).
- The training rows are single-intent.

Six tasks can't be expressed, so the model picks `chat` or `list` and its reply sentence is shown. Changing models cannot fix this; it's why Qwen and Gemma fail the same way.

**R2. Whole-message keyword routes fire on words from different bullets.**
`_negatedCancelRoute` ([session.dart:1289-1342](../../lib/assistant/session.dart)) runs before the model in both interpreters. In the digest:
- "don't notify you" in one bullet made the whole message `negated`;
- "notify" counted as a reminder word;
- "ChatGPT Plus cancel on Nov 3" supplied the cancel verb;
- "Aditya" in another bullet matched the existing "call aditya" reminder.

None of these words belong to the same request.

**R3. Negation and tentativeness are judged on the whole message.**
`readAuthorization(text)` ([session.dart:441](../../lib/assistant/session.dart)) and `RuleEngine.isNegated(text)` in `_create` ([session.dart:2550](../../lib/assistant/session.dart)) look at every word. One "haven't" in bullet 1 blocks a correct create for bullet 4 ("Okay, I won't save that."), and `isTentative` gives "sounds undecided".

**R4. The rule parser handles one task.**
- `parseCreate` reads one task.
- `_multiRe` ([rule_engine.dart:400](../../lib/assistant/rule_engine.dart)) only *detects* "and + verb", in order to refuse ("Send them one at a time").
- Bulleted or numbered lines are not recognized at all.

**R5. A pasted digest is not a list of commands.**
Screenshot 1 mixes:
- statements ("X is due tomorrow");
- status notes ("still unconfirmed", "on hold until the client replies");
- questions ("Tell me if you already got it");
- items that are already tracked.

Turning every line into a task would create junk and duplicates. Some items need confirming before anything is written.

**R6. A `list` plan can leave a reply that claims a listing.**
When the list branch hands back to chat (`command()` is true because of "Add"; [session.dart:2372-2373](../../lib/assistant/session.dart)), the model's "Here is the full picture…" is shown with nothing listed.

### Fix design

The model stays single-item; splitting and batching are app-side and deterministic. Per-item model calls are too slow for this: about 10 s each at today's decode speed.

**MB.1 Batch reader** (new `lib/assistant/batch.dart`):
```dart
class BatchItem { final String text; final String? section; const BatchItem(this.text, this.section); }
class BatchRequest {
  final List<BatchItem> items;
  final bool explicit;      // "add these tasks", "add the following", "tasks:", "remind me about these"
  const BatchRequest(this.items, {required this.explicit});
}
/// Null unless [text] holds 2+ separable items.
BatchRequest? readBatch(String text);
```
- Items come from:
  - lines starting `-`, `*`, `•`, `1.` or `1)`;
  - or, for short messages, `_multiRe`-style "and/then/also + verb" joins ("buy milk and call mom tomorrow" gives 2; "call mom and dad" stays 1).
- Markdown is stripped (`**`, `__`, `#`). A bold-only line ("**Due soon**") becomes the `section` of the following items. Lone `*` or blank lines are dropped.
- More than 10 items gives one reply: "That's N items; send up to 10 at a time."

**MB.2 Batch route first.** In `_coordinate` ([session.dart:977](../../lib/assistant/session.dart)) and the legacy `_route` (932), run `readBatch` right after `pendingPick`/`calculator`/`pendingAnswer`, before `complaint`, `negatedCancel`, `briefing` and `semantic`. A batch never reaches the whole-message routes (fixes R2 for batches).

**MB.3 Per-item reading, rules first.** For each item, against the turn's captured `now`:
- `_fallback.parseCreate(item)` and `Temporal.read(item, now)`;
- negation, tentativeness and question checks **on the item only** (fixes R3 for batches);
- `taskRepo.relevantTasks(item)` / `named()` to find a matching open task.

Each item gets one class:

| Class | When | Action |
|---|---|---|
| `create` | clear action phrase | task; due date or deadline when a date is given; reminder only with a remind/notify cue or an explicit "remind me about these" header |
| `daily` | "every day / daily at …" | the existing daily-schedule create |
| `tracked` | matches an open task | nothing new; listed as already tracked (#id) |
| `skip` | status note, question, negated, too vague | nothing; listed with the reason |

Unclear items may use the model, at most 2 per batch (batch-only plan budget of 3). The plan prompt's system block is identical across items, so the second and third calls reuse the KV cache. Every other unclear item is listed as "tell me this one in your own words".

**MB.4 Preview, then confirm (no writes yet).** The reply shows the classification and stores a `BatchDraft` under `PendingRepo` key `batch:<chat>`, valid 30 minutes, the way `pick:<chat>` is stored ([session.dart:2939](../../lib/assistant/session.dart)). For the screenshot-2 message the preview would read:
```
I found 6 items. I'll add:
1. Sachiv V1 — due Fri 31 Oct
2. SurveyMonkey credits — until Thu 19 Nov
3. Post on X and Instagram — today 5:00 PM
4. Dispose of the covers — daily at 9:00 AM
5. Dispose of the covers — daily at 6:00 PM
Already tracked: Aditya's update (#<id> call aditya)
Not added: Jaydeb's ₹60 is waiting for your answer (a question, not a task)
Say "yes" to add all 5, "only 1 and 3", or "no".
```
(`create_daily` takes one time, [tools.dart:527-529](../../lib/assistant/tools.dart), so two daily times are two entries.)
The next turn accepts:
- "yes" / "add all" → commit all;
- "only 1 and 3" / "drop 2" → the chosen subset;
- "no" / "cancel" → discard.

Anything else drops the draft and is handled normally. Whether a short explicit batch (an "Add these tasks:" header, ≤ 3 clean creates, nothing skipped) may skip the preview is decision 6.

**MB.5 One atomic commit.**
- A new write tool `create_batch {items: [...]}` (family `report`, so `isWrite`). The executor ([tools.dart](../../lib/assistant/tools.dart)) runs the existing per-item `create_task` / `create_reminder` / `create_daily` code in one transaction, with per-item `op_id` = `<op>#<index>`.
- Crash recovery finds committed rows by op id and creates only the missing ones; the `op_id` columns on tasks and reminders already exist (schema v7).
- The reply lists what was saved with ids. Reminders sync once after the transaction.

**MB.6 Sentence-scoped guards (also helps single messages).**
- `_negatedCancelRoute`, `_briefingRoute`, `_progressRoute`, `_outcomeRoute` and `_detailsRoute` fire only when their trigger words occur **in one sentence or line**.
- `_create`'s negation check (session.dart:2550) looks only at the clause containing the plan's `title` words.

Today's single-sentence tests must stay green.

**MB.7 Never show a listing claim without a listing (R6).** If the plan intent is `list` but no list tool runs, drop the plan reply and use the rules reply.

**MB.8 Training (with the 3.3/3.4 retrain, row 14).**
- Add single-item rows written in the style of list items (no leading verb, markdown stripped), so per-item model fallback is in distribution.
- Add status-note rows ("X is still unconfirmed", "on hold until the client replies") labelled `chat`/`progress`, so the model doesn't invent creates from digests.
- No multi-item output format.

### Tests

New file `test/multi_item_test.dart`, built from the reproduction above:

| # | Message | Expect |
|---|---|---|
| B1 | screenshot-1 digest (no header) | preview with classes; nothing written; route never `negated_cancel` |
| B2 | screenshot-2 "Add these tasks" | preview exactly as in MB.4 |
| B3 | B2, then "yes" | 3 tasks and 2 daily schedules created in one operation; existing "call aditya" untouched |
| B4 | B2, then "only 1 and 3" | 2 tasks created |
| B5 | B2, then "no" | nothing created; draft cleared |
| B6 | B3 with a simulated crash after item 2, then retry | no duplicates; items 3–4 created |
| B7 | "add buy milk and call mom tomorrow" | 2 items (preview or direct, per decision 6) |
| B8 | "Add these tasks:\n- buy milk\n- don't remind me about gym" | buy milk created; gym item skipped as negated |
| B9 | 12 bullets | "send up to 10 at a time"; nothing written |
| B10 | "don't cancel my gym reminder" (single sentence) | unchanged: "Okay, your gym reminder stays." |
| B11 | a 20-line paste | never `prompt_too_long` (the batch never goes to the model whole) |

**Device check:** paste the screenshot-2 text on the POCO F5, then "yes". The Tasks tab shows the 3 new tasks and the 2 daily schedules; record turn timings for both messages.

**Suggested models:**
- MB.1 and MB.6: standard (Claude Sonnet or Codex). Use Gemini Pro to generate 50 varied paste examples for the tests.
- MB.2–MB.5: high reasoning (Claude Opus or Codex at high effort). Routing order, pending interactions, and atomic commit with crash recovery.
- MB.8: Claude Opus for the data design.

---

## 6. Phase 1: memory that lasts

### 1.1 History table (schema v11)

**DDL** (new `_createMemoryHistory` in [db.dart](../../lib/data/db.dart); called from `onCreate` and from `onUpgrade` as `if (oldVersion < 11 && newVersion >= 11)`; `dbVersion = 11`):
```sql
CREATE TABLE memory_history(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_id INTEGER NOT NULL,              -- no FK: history outlives a purge
  event TEXT NOT NULL CHECK(event IN ('add','bump','supersede','delete','restore','purge','edit','accept','reject')),
  old_content TEXT, new_content TEXT,
  actor TEXT NOT NULL CHECK(actor IN ('user','rules','model','system')),
  op_id TEXT,
  created_at INTEGER NOT NULL);
CREATE INDEX memory_history_mem ON memory_history(memory_id, id);
ALTER TABLE memories ADD COLUMN deleted_at INTEGER;   -- 1.2
ALTER TABLE memories ADD COLUMN expires_at INTEGER;   -- 1.4 (column now, feature later)
```
Add each column only if `PRAGMA table_info(memories)` lacks it, as `_createMemoryIndexing` does. Memory status values become `active | superseded | deleted | suggested`.

**MemoryRepo changes** ([repos.dart:1158](../../lib/data/repos.dart)):
- A private `Future<void> _log(String event, int memoryId, {String? old, String? now, required String actor, String? opId})`.
- `add(..., {String actor = 'rules'})`: log `bump` on the dedupe path, `add` on insert, and `supersede` for each superseded row (inside the existing transaction).
- New `Future<int> addCorrection(String content, {required String replaces, ...})`. It runs `add` plus the superseding that today lives in tools.dart:576-591 in one transaction. Candidate lookup uses FTS AND (`memories_fts MATCH 'term1 term2'`, FTS4's implicit AND) joined to `status = 'active'`, then the same "every term contained" filter and the same `≤ 3` cap. No `all()` scan.
- New `Future<int?> activeIdForContent(String content)` (hash lookup). It replaces the recovery scan at tools.dart:563.
- New `Future<List<Map<String, Object?>>> history(int memoryId)`.

**Callers:**
- tools.dart `save_memory`: pass `actor`. Use `'user'` when the source turn was an explicit "remember"; add `'explicit': true` to `_memoryEffect` args at [session.dart:743](../../lib/assistant/session.dart). Otherwise use `'rules'`.
- Memories page add ([memories_page.dart:599](../../lib/ui/memories_page.dart)): `'user'`.

**Tests:**
- v10 → v11 migration from a v10 file, modelled on the existing v9 → v10 test. Update `expect(dbVersion, 10)` at [p3_p6_architecture_test.dart:127](../../test/p3_p6_architecture_test.dart).
- Each mutation writes exactly one history row of the right event.
- A failed insert rolls back its history row: throw inside the transaction and assert.

**Suggested model:** high reasoning for the migration and transaction design; standard for the call-site edits.

### 1.2 Soft delete, undo and purge

**Repo** (all in one transaction each):
- `delete(int id, {String actor = 'user', String? opId})`: `UPDATE memories SET status='deleted', deleted_at=? WHERE id=? AND status='active'`, then `DELETE FROM memories_fts WHERE docid=?` and log `delete`. Returns whether a row changed.
- `restore(int id)` returns a `RestoreResult`:
  - `restored` when the row is `deleted`;
  - `duplicate` when an active row has the same `content_hash` (nothing changes; returns that id);
  - `slotTaken` when an active row holds the same slot (nothing changes);
  - `gone` otherwise.
  On restore: status `active`, `deleted_at` null, `INSERT INTO memories_fts(docid, content)`, log `restore`.
- `deletePermanently(int id)`: hard delete (the FTS trigger fires), then `UPDATE memory_history SET old_content=NULL, new_content=NULL WHERE memory_id=?`, then log `purge` with no content. This is the privacy path.
- `purgeDeleted({Duration olderThan = const Duration(days: 30)})`: `deletePermanently` for every `status='deleted' AND deleted_at < ?`. It runs as a new startup step next to `step('catch up', …)` in [app_services.dart:283](../../lib/services/app_services.dart).

**All existing reads already filter `status = 'active'`** (dedupe, slot, search, `all`, `important`, `relevantForContext`), so deleted rows leave prompts with no further change. Verify this with a test per read method.

**Chat:**
- Executor reply for `delete_memory`: `Forgot "<content>". Say "undo" to bring it back.`
- Optional 1.2b: an `undo` rule. If the message matches `^(?:undo|bring it back|restore (?:it|that))[.!]*$` and the last receipt in this chat was a `delete_memory` within 10 minutes, then `restore(id)`. Store `undo:<chat>` in `PendingRepo` the way `pick:<chat>` is stored ([session.dart:2939](../../lib/assistant/session.dart)).

**Memories page** ([memories_page.dart](../../lib/ui/memories_page.dart)):
- Delete shows a SnackBar "Memory deleted · Undo" (5 s).
- A collapsible "Recently deleted" section with Restore and "Delete permanently" (with confirm).
- Tapping a memory opens a sheet with its history (date, event, actor).

**Tests:**
- delete → not in `search`, `all`, `important` or `relevantForContext`; present via a deleted-list query.
- restore → back in search.
- restore when duplicate → `duplicate`, no second active row.
- restore when the slot was refilled → `slotTaken`.
- `deletePermanently` → row gone; history content nulled.
- purge respects the 30-day boundary (injected clock).
- Widget test for SnackBar undo.

**Suggested model:**
- Repo and tests: standard.
- UI: Codex (this matches how UI work has gone in this repo) or Claude Sonnet.

### 1.3 Temporal ingestion

**New resolver** in [temporal.dart](../../lib/assistant/temporal.dart). `Temporal.read` targets reminder times and has no past phrases, so add a separate, narrow resolver:
```dart
/// The calendar date a remembered fact refers to, resolved against when it
/// was said. Null when there is none or it is ambiguous; never a guess.
({String value, bool recurring})? resolveFactDate(String text, DateTime observedAt);
```
Supported phrases and outputs (local date of `observedAt`):

| Phrase | Value |
|---|---|
| today / yesterday / tomorrow | `YYYY-MM-DD` |
| N days/weeks ago, in N days/weeks | `YYYY-MM-DD` |
| last / next / this \<weekday\> | `YYYY-MM-DD` |
| ISO `2026-11-02`; "2 November 2026", "Nov 2 2026" | `YYYY-MM-DD` |
| month-day without year **and** a recurring cue (birthday, anniversary, every year) | `--MM-DD`, recurring |
| bare "on Monday" with a future cue (is on, will, going to, have … on) | next Monday |
| bare "on Monday" with a past cue (was, went, had, met, did) | previous Monday |
| anything else (bare weekday with no cue, "recently", month-day with no year and no cue) | null |

**Repo/session wiring:**
- `MemoryRepo.add(..., DateTime? observedAt)` writes:
  - `observed_at_utc = observedAt.toUtc().millisecondsSinceEpoch`
  - `observation_offset_min = observedAt.timeZoneOffset.inMinutes`
  - `fact_date = resolveFactDate(content, observedAt)?.value`
- Session adds `'observed_at': _turnNow` to the `save_memory` args ([session.dart:743](../../lib/assistant/session.dart)). `encodeArgs` already encodes `DateTime` (turn_contract.dart ~200), so journal recovery replays the same instant. tools.dart passes it to `add`.
- `indexMemoryRows` stays as is (old rows keep null temporal fields; there is no observation date to recover).

**Rendering:** a memory with `fact_date` renders with the absolute date wherever it reaches a prompt or a reply:
- plan `memories` list (session.dart:2159)
- `_personalMemories` (line 1588)
- recall replies

Format: `"User's exam is on Monday (2 Nov 2026)"`; recurring: `"(every year on 4 June)"`. Do the formatting in one helper next to `buildPersonalContext`.

**Backup format v3** ([backup_format.dart](../../lib/services/backup/backup_format.dart)):
- `backupFormatVersion = 3`.
- Memory columns `observed_at_utc` (intOrNull), `observation_offset_min` (intOrNull), `fact_date` (textOrNull), `deleted_at` (intOrNull), `expires_at` (intOrNull).
- A new optional `memoryHistory` table section.
- `_checkMemory` accepts `deleted` and `suggested`.
- v1 and v2 archives still restore (absent fields become null). Update the doc comment at lines 5-12.

**Tests** (`test/temporal_test.dart` plus a new `test/memory_temporal_test.dart`):
- Every row of the table above, with observedAt = Fri 30 Oct 2026 14:00 local. Examples: "my exam is on Monday" → `2026-11-02`; "I met Priya on Monday" → `2026-10-26`; "my mom's birthday is June 4" → `--06-04`; "I went to Goa recently" → null.
- `add` stores all three fields.
- Journal-recovery replay stores the same `observed_at_utc`.
- Backup v3 round trip keeps them; a v2 fixture still restores ([test/support/backup_fixture.dart](../../test/support/backup_fixture.dart)).

**Suggested model:** high reasoning (Claude Opus or Codex at high effort). Date semantics and edge cases are the main risk. Gemini Pro is a good second reviewer for the phrase table.

### 1.4 Optional expiry (decision 2)

- `expires_at` exists from 1.1.
- If you choose to store time-bound facts, then `isTemporary` texts ("I'm in Goa this week") are stored with `expires_at = end of the resolved window`, or `observedAt + 7 days` when unresolved, instead of being refused.
- One-off dated facts get `expires_at = fact_date + 30 days`.
- All reads add `AND (expires_at IS NULL OR expires_at > ?)`.
- `purgeDeleted` also soft-deletes expired rows with actor `system`.

**Suggested model:** standard.

### 1.5 Write-time instruction scan

`String? memoryInstructionIssue(String content)` in [core_policy.dart](../../lib/assistant/core_policy.dart). It is checked in `_memoryCandidate` (explicit and implicit) and in `MemoryRepo.add` (defence in depth). Reject when the content, after stripping a leading `user`/`i`/`my` subject:
- addresses the assistant: `\b(you|assistant|corenyth)\b` together with `\b(must|should|always|never|will|have to)\b`; or
- starts with an imperative: `always|never|don't|do not|ignore|forget all|pretend|act as|from now on`; or
- contains role or control markers: `system:`, `assistant:`, `<|`, `###`.

Allowed: "I never drink coffee", "User prefers short answers" (the answer-style slot exists).

Reply: "I keep facts about you, not instructions for me. To change how I reply, use Memories → Edit tone."

**Tests:** 8 reject and 8 allow cases, listed in the test file.
**Suggested model:** standard.

### 1.6 Persistence checks

1. **Journal mode.** First log the current mode on the phone (`PRAGMA journal_mode` in a debug log at startup). If it is not `wal`, run `rawQuery('PRAGMA journal_mode=WAL')` in `onConfigure` ([db.dart:25](../../lib/data/db.dart)) and confirm the widget still reads tasks. Crash test: send a message, then `adb -s 462a848c shell am force-stop com.corenyth.assistant` within 1 s; on relaunch the user message and journal row exist.
2. **In-app backup round trip:** active, superseded, deleted and suggested memories, plus history, survive export → import (`backup_service_test.dart`).
3. **Auto Backup (N9, decision 5).** If you want memories in Google's backup, add `android:dataExtractionRules` (API 31+) and `android:fullBackupContent` (older APIs):
   - include the `database` domain `assistant.db`;
   - exclude `files/models/` and `files/backups/`.
   Verify on an **emulator** (never the POCO F5): `adb shell bmgr backupnow com.corenyth.assistant`, reinstall, restore, memories present.

**Suggested model:**
- Manifest and backup rules: Codex or Claude Sonnet.
- Investigating the journal mode and crash safety: high reasoning.

---

## 7. Phase 2: retrieval at scale

### 2.1 Benchmark first

- **Generator** `test/support/memory_seed.dart` (seeded `Random(8426)`), with templates for:
  - each slot (drink, residence, occupation, meeting time, answer style)
  - people ("My sister Priya lives in Pune")
  - hobbies, dated facts and noise
  It inserts N ∈ {1k, 5k, 20k} via `MemoryRepo.add` in batches.
- **Labelled queries** `test/fixtures/memory_queries.json`: 50 entries `{query, expect_contains: [...]}`, covering exact, paraphrase, prefix and person queries.
- **Bench** `test/memory_bench_test.dart`, tagged `bench` and excluded from the default run. Reports for `search`, `relevantForContext` and `important`:
  - p50/p95 over 200 runs
  - recall@3 and MRR
- **Phone:** run the same bench via `integration_test` (add the dev dependency), using `flutter test integration_test/memory_bench_test.dart -d 462a848c`.
- Record baseline numbers in this doc before changing anything.

**Suggested model:**
- Generator and harness: Codex or Claude Sonnet.
- Labelling the query set: Gemini Pro (bulk text work), checked by you.

### 2.2 Two-stage candidate selection

**Stage 1 (no content loaded):**
```sql
SELECT m.id, m.importance, m.updated_at, matchinfo(memories_fts, 'pcnalx') AS mi
FROM memories_fts JOIN memories m ON m.id = memories_fts.docid
WHERE memories_fts MATCH ? AND m.status = 'active'
```
- Decode `mi` (uint32 little-endian, `ByteData.getUint32(i * 4, Endian.little)`).
- Compute Okapi BM25 (k1 = 1.2, b = 0.75) from p, c, n, a, l, x.
- Normalize with Mem0's sigmoid (`get_bm25_params`: midpoint/steepness by term count; `mem0/utils/scoring.py`).
- `stage1 = bm25n * 2 + importance + 1 / (1 + ageDays / 30)` (same weights as today, with BM25 replacing raw hit share).
- Keep the top `max(limit * 4, 60)` ids.

**Stage 2:** `SELECT * FROM memories WHERE id IN (…)`, then today's exact term-hit score as a tie-break, then `take(limit)`.

**Alternative B, if matchinfo is slow on the phone:** an AND query first; fall back to the OR query only when fewer than `limit` rows are found. Pick A or B by the 2.1 numbers.

**Done:** p95 under 20 ms at 5k memories on the phone, and recall@3 at least the baseline.
**Suggested model:** high reasoning (Claude Opus or Codex at high effort). Ranking math plus the FTS4 binary format.

### 2.3 Bounded `important()`

Page through `status='active' AND category IN ('preference','fact','person') ORDER BY importance DESC, updated_at DESC LIMIT 50 OFFSET ?` until `limit` rows pass `isUsefulPersonalMemory`, at most 5 pages.

**Suggested model:** standard.

### 2.4 Entity boost (only if 2.1 shows misses)

- **Table:** `memory_entities(memory_id INTEGER NOT NULL, entity_key TEXT NOT NULL, PRIMARY KEY(memory_id, entity_key))`, with `CREATE INDEX memory_entities_key ON memory_entities(entity_key)`.
- **Filled at add time from:**
  - slot subject (when not `user`)
  - relation words (`my sister|brother|mom|dad|wife|husband|partner|friend|boss`), normalized
  - capitalized tokens not at the sentence start
- **Boost:** `0.5 × shared / queryEntities`, as Mem0's `ENTITY_BOOST_WEIGHT`.

**Suggested model:** standard.

### 2.5 Batch `last_accessed_at`

One `UPDATE memories SET last_accessed_at = ? WHERE id IN (…)`.

**Suggested model:** standard (or fast: Claude Haiku or Gemini Flash).

---

## 8. Phase 3: model scheduling and speed

### 3.1 Model scheduler (needed once background work exists, i.e. 4.3)

`lib/assistant/model_scheduler.dart`, owned by `AppServices` and wrapping the engine:
```dart
enum ModelPriority { foreground, optional, background }

class ModelScheduler {
  Future<String?> run(Prompt p, ModelPriority pr,
      {void Function(String raw)? onRaw, void Function(String text)? onText, String? jobKey});
  void noteTurn(); // resets the idle clock
}
```
Rules:
- `foreground` cancels running and queued `optional`/`background` work (`cancelOptional` from 0.3).
- `background` is admitted only after 60 s with no turn and nothing queued.
- `optional` work from an older epoch is dropped.
- `jobKey` failure counter: 2 failures → blocked, logged, never retried (Hermes `failure_limit`).
- Sessions call `scheduler.run` instead of `engine.completeStreaming`; `_complete` keeps its per-turn budget and cache.

**Tests:** preemption order, idle gate (fake clock), failure limit, stale drop.
**Suggested model:** high reasoning.

### 3.2 Measure KV reuse (no code needed to start)

Script of 20 turns, typed in order on the phone:
- 6 rule-routed creates
- 8 chats
- 3 recalls
- 3 lists

Capture with `adb -s 462a848c logcat -s LlamaBridge > run.log`. A small parser (`training/parse_llama_log.py`) reports per request: prompt tokens, reused %, prefill ms, decode tok/s, generated tokens.

Runs:
- (a) before Phase 0
- (b) after 0.2/0.3
- (c) after 3.3/3.4

**Optional:** return `{prompt_tokens, reused, prompt_ms, generated, gen_ms}` to Dart for turn diagnostics. That changes the channel contract, so only do it if the logcat route becomes a bottleneck.

**Suggested model:** standard for the parser; analysing the numbers is your call or high reasoning.

### 3.3 Cache-friendly prompt layout (retrain; decide after 3.2 run b)

After 0.2 the mood job shares the plan layout, so the remaining switch is plan → reply inside a turn. If run (b) shows that switch is frequent and costly:
- Give both contracts one shared system block (identity + `emotionGuide` + `toneGuide` + personality + "About the user"), put the contract-specific instructions next, and keep variable parts last.
- Move reply-path memories from the system block to the user turn (session.dart:1729-1731).

Steps:
1. Change `_renderPlan`/`_renderReply` (engine.dart:262-315).
2. Update `training/app_prompts.py` and keep `training/export_prompts_test.dart` parity green.
3. Rebuild the bundle (`training/make_bundle.py`).
4. Retrain with the Colab cells (`training/colab_cells.py`).
5. Evaluate, then export Q4_0.
6. Update the allowlist (name, size, sha) in [model_status.dart](../../lib/services/model_status.dart) and [test/model_selection_test.dart](../../test/model_selection_test.dart).
7. Upload the release asset.

**Suggested model:** high reasoning (Claude Opus). Prompt contract and training data design; Codex for the script edits.

### 3.4 Shorter outputs (same retrain)

- **Reply contract:** "one short sentence, at most 14 words" in `replySystem`, plus `training/reply_banks.json` regenerated within that limit.
- **Envelope:** measure a 1-decimal variant (`mnum ::= [0-1] "." [0-9]`, saving about 4 tokens) before adopting it. It changes `emotionGrammar`, `MoodReading` parsing tests and the training rows.
- **Retrain gates against the current model's eval** (`colab_cells.py` `evaluate`):
  - valid_json 100%
  - intent_ok and mood_ok no lower
  - reply_le12_words ≥ 95%
- **Device target:** warm turn p50 ≤ 6 s interim, 4 s goal, measured with the 3.2 script.

**Suggested model:** Claude Opus for the data design; Codex for the script edits; Gemini Pro to review the generated reply banks in bulk.

### 3.5 Two KV sequences (only if 3.3 is not enough)

- One sequence per contract (`n_seq_max = 2`), with reuse tracked per sequence.
- Extra memory for Qwen3-0.6B: 28 layers × 8 KV heads × 128 dims × 2 (K, V) × 2 bytes = 112 KiB per token, about 224 MiB for 2,048 tokens. A q8_0 KV cache halves that.
- Needs the same determinism check as 0.3.

**Suggested model:** high reasoning.

---

## 9. Phase 4: reminders and background work

### 4.1 "While you were away" summary (N11)

In `catchUp()` ([proactive.dart:243](../../lib/services/proactive.dart)):
- Select `enabled = 1 AND trigger_at <= now - _catchUpWindow`.
- Write **one** main-chat message via `conversations.addProactive('missed-summary:<yyyy-mm-dd>', text, kind: 'missed')`, e.g. "While the app was closed, 3 reminders passed: call mom (Tue 5 pm), …", listing up to 5 plus "and N more".
- Then disable those rows (`enabled = 0`, `sync = 'cancel'`) so they're never counted again.
- No notification (no flood).

**Tests** in `test/proactive_delivery_test.dart`:
- 0 misses → no message.
- 7 misses → one message, 5 listed + "and 2 more".
- A second `catchUp` writes nothing.
- Misses inside 12 h keep today's per-task behaviour.

**Suggested model:** standard.

### 4.2 Task "cancelled" status: deferred

The `tasks.status` CHECK allows only `pending`/`done` ([db.dart:31](../../lib/data/db.dart)). Changing it needs a table rebuild, and the widget reads that table. Revisit only if the product wants undoable task deletes. The additive alternative is a `deleted_at` column plus a filter in every task query and the widget SQL.

### 4.3 Idle-time memory extraction (opt-in; decision 3)

- **State:** `extraction_state(chat_id TEXT PRIMARY KEY, last_message_id INTEGER NOT NULL)`.
- **Job:** via `ModelScheduler.run(..., ModelPriority.background, jobKey: 'extract:<message id>')`. It runs only while the app is open and idle (3.1). It takes at most 5 user messages after the watermark, skipping messages that already produced a memory effect and those where `isTemporary` is true.
- **Prompt:** one message per call, using the existing `PromptKind.memory` contract and grammar (engine.dart:208-215).
- **Result:** a row with `status = 'suggested'`, `source = 'model:extract'`, actor `model`. It is not in FTS and not in prompts.
- **Memories page:** a "Suggestions" section. Accept → normal `add` (dedupe and slot supersede), history `accept`. Reject → `deletePermanently`, history `reject`.
- **Never** deletes or edits existing memories (Mem0 v3: ADD only).
- **Check first** whether the current fine-tune covered the memory contract (`training/build_dataset.py`). If not, add memory rows to the 3.3/3.4 retrain before enabling this.
- **Eval:** 100 labelled messages (`test/fixtures/memory_extract.json`). Precision ≥ 90% before shipping; recall is secondary.

**Suggested model:** high reasoning for the pipeline; Gemini Pro to draft the 100 labelled messages (you review them).

---

## 10. Phase 5: evidence and documentation

1. **One current status table** in [reliability-status.md](reliability-status.md). Columns: *Capability | Implemented | Host-tested | Device-observed | Release-qualified | Commit | Model sha256 | Date*. Example row: "Optional mood off the confirmation path | yes (c6492e2) | yes (p3_p6_architecture_test) | no | no | …".
2. **A snapshot header on every historical report** (acceptance report, next-steps, performance-validation, device-evaluation), content unchanged:
   > Snapshot: commit `c6492e2` · model `Corenyth-Qwen3-0.6B-mood-Q4_0` (sha256 `f2086705…`) · `flutter test` 538 pass / 3 skipped · host macOS, device POCO F5 · 2026-10-30. Historical; current state lives in reliability-status.md.
3. **Specific corrections:**
   - [known-gaps.md:48](known-gaps.md): "dedupe uses the indexed `content_hash`; retrieval is still unbounded before ranking (Phase 2)".
   - known-gaps.md line 74: drop "Indexed memory deduplication" from the outstanding list.
   - [architecture-acceptance-report.md](architecture-acceptance-report.md):
     - line 3: "P0–P6 implemented; 3 multi-turn scenarios incomplete; device qualification open"
     - line 14: "reduces instruction-injection risk (reference-only framing, ChatML neutralization); not proven impossible"
     - lines 16 and 51: label as historical counts (512 / 510) and point to the current count.
4. **The 3 incomplete multi-turn scenarios:** fix them, or list each with its reason in reliability-status.md.
5. Cross-link this plan from section 18 of [Corenyth-Documentation.html](../Corenyth-Documentation.html).

**Suggested model:** Gemini Pro. Its long context suits reading all ten docs and the code at once. Claude Sonnet then makes the edits, and you approve the wording.

---

## 11. Phase 6: splitting `session.dart` (3,260 lines)

Start after Phases 0–3 land. Step one has zero behaviour change: move method groups into **part files as private extensions** on `AssistantSession`. Part files share the library, so private members stay reachable and the fields stay in the class. Group the moves by responsibility:

| New part file | Moves (current lines) |
|---|---|
| `session_memory.dart` | `_memoryCandidate` (3161), forget branch (from `_plan`, 751-778), `_personalMemories` (1588) |
| `session_mood.dart` | `_emitMood` (1663), `_dispatchOptionalMood`/`_runOptionalMood` (638-709) |
| `session_pending.dart` | drafts, picks, `_applyPending` (2908-2998) |
| `session_rules.dart` | rules fallback (3000+) |
| `session_reply.dart` | grounded reply generation (~1700-1800), `_streamedDraft` (1650) |
| `session_commit.dart` | `_commit`, `_replay`, `_abandon` (~600) |

Rules:
- One group per change.
- The full suite passes after each move.
- No renames in the same change.
- Narrowing interfaces (real classes) is a later, separate step.

**Suggested model:**
- Claude Opus, or Gemini Pro (to hold the whole file) paired with Claude for the edits.
- Each move reviewed with `git diff --stat` plus the test run.

---

## 12. Order, sizes and suggested models

Sizes: S ≈ under half a day, M ≈ 1–2 days, L ≈ 3+ days including device checks.

**Model tiers (suggestions only; use what you have at hand):**
- **High reasoning:** Claude Opus at high effort, or Codex at its highest reasoning effort. Use for concurrency, native code, schema/migration, ranking math, prompt/training design and large refactors.
- **Standard:** Claude Sonnet or Codex at default effort. Use for well-specified Dart changes with clear tests, and UI.
- **Long context:** Gemini Pro. Use for reading many files at once (doc reconciliation, holding all of `session.dart`), bulk labelling or review of generated data.
- **Fast:** Claude Haiku or Gemini Flash. Use for one-line mechanical edits and log parsing.
- **Always** review with a different model than the one that wrote the change.

| # | Task | Size | Depends on | Retrain | Suggested model (alternative) |
|---|---|---|---|---|---|
| 1 | 0.1 Safe forget | S | none | No | Standard: Sonnet (Codex) |
| 2 | 0.3 Preemption + cache-safe cancel | M | none | No | High: Opus (Codex high) |
| 3 | 0.2 Mood via plan prompt, accept once | M | 0.3 (`completeOptional`) | No | High: Opus (Codex high) |
| 4 | 3.2 run (a)/(b) measurement | S | before/after 0.2–0.3 | No | Fast: Haiku/Flash for the parser |
| 4a | MB.6 Sentence-scoped guards + MB.7 | S | none | No | Standard: Sonnet (Codex) |
| 4b | MB.1 Batch reader | S–M | none | No | Standard: Sonnet (Codex); Gemini Pro for paste examples |
| 4c | MB.2–MB.5 Batch route, per-item reading, preview, atomic commit | M–L | MB.1 | No | High: Opus (Codex high) |
| 5 | 1.1 History + v11 | M | none | No | High: Opus for migration; Sonnet for call sites |
| 6 | 1.2 Soft delete, undo, purge, UI | M | 1.1 | No | Standard: Sonnet (repo); Codex (UI) |
| 7 | 1.3 Temporal + backup v3 | M | 1.1 | No | High: Opus (Codex high); Gemini Pro review |
| 8 | 1.5 Instruction scan | S | none | No | Standard: Sonnet (Codex) |
| 9 | 1.6 Persistence checks | S–M | 1.1–1.3 | No | Standard: Codex; High for crash-safety analysis |
| 10 | 5 Docs reconciliation | S | 0.x, 1.x landed | No | Long context: Gemini Pro, then Sonnet edits |
| 11 | 2.1 Benchmark | M | none | No | Standard: Codex (Sonnet); Gemini Pro for labels |
| 12 | 2.2 / 2.3 / 2.5 Retrieval | M | 2.1 | No | High: Opus (Codex high) for 2.2; Standard for the rest |
| 13 | 4.1 Missed-reminder summary | S | none | No | Standard: Sonnet (Codex) |
| 14 | 3.3 + 3.4 Layout + shorter outputs | L | 3.2 (b) | **Yes** | High: Opus (data design); Codex (scripts); Gemini Pro (bank review) |
| 15 | 3.1 Scheduler | M | 0.3 | No | High: Opus (Codex high) |
| 16 | 4.3 Idle extraction (opt-in) | M | 3.1, 1.1, retrain if needed | Maybe | High: Opus; Gemini Pro for eval data |
| 17 | 1.4 Expiry, 2.4 Entities | S each | 1.1 / 2.1 | No | Standard: Sonnet (Codex) |
| 18 | 6 Split `session.dart` | M | 0–3 landed | No | High: Opus, or Gemini Pro + Claude |
| 19 | 3.5 Two KV sequences | M | only if 14 is not enough | No | High: Opus (Codex high) |
| n/a | 4.2 Task cancelled status | deferred | product decision | No | n/a |

**Milestones:**
- **M1, safe and quicker (rows 1–4c):** wrong-memory deletion impossible; mood job about 25 tokens; no queueing behind it; measured reuse; several tasks in one message are previewed and added together.
- **M2, durable memory (rows 5–10):** history, undo, dates, safe content, verified backups, honest docs.
- **M3, scale and speed (rows 11–15):** bounded retrieval with numbers; one retrain for layout and length; scheduler.
- **M4, extras (rows 16–19).**

---

## 13. Decisions for you

1. **Undo window** for deleted memories: 30 days proposed.
2. **Time-bound facts:** keep rejecting them, or store with expiry (1.4)?
3. **Model-extracted memories (4.3):** suggest only (recommended), or auto-save above a confidence?
4. **Retrain scope:** bundle the layout change (3.3) with shorter outputs (3.4) in one retrain? Recommended, but only if run (b) of 3.2 shows the plan → reply switch is still costly.
5. **Google Auto Backup** of the memory database (1.6.3): turn it on (excluding models), or keep the in-app backup file as the only copy?
6. **Multi-task preview (MB.4):** always preview before adding several tasks (recommended), or add directly when the message says "add these tasks" and has ≤ 3 clean items?
