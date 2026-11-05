import 'dart:async';
import 'dart:convert';

import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/v2_db.dart';

/// Plan 1.3: memories keep when they were said (instant + offset) and the
/// absolute day they refer to, through writes, journal replay and cancel.

const _timeout = Duration(seconds: 5);
// "yesterday" resolves against the observation day, so a retry on another
// day would differ. A one-off dated fact expires 30 days after its day
// (plan 1.4), and the reply says so.
const _said = 'remember that I met Priya yesterday';
const _fact = '2026-10-29';

/// Fri 30 Oct 2026 14:00 local, as in the plan's phrase table.
final _observed = DateTime(2026, 10, 30, 14);

/// The FTS4 index a fresh install has; the host v2 migration lacks it.
Future<Database> _db() async {
  final db = await openMigratedV2();
  await db.execute(
      'CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts4(content, tokenize=unicode61)');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS mem_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(docid, content) VALUES (new.id, new.content); END''');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS mem_ad AFTER DELETE ON memories BEGIN
      DELETE FROM memories_fts WHERE docid = old.id; END''');
  return db;
}

/// A process death at the memory write: before or after the row commits.
class _CrashError implements Exception {}

class _Tools extends ToolExecutor {
  _Tools(TaskRepo tasks, ReminderRepo reminders, MemoryRepo memory,
      DateTime Function() clock)
      : super(tasks, reminders, memory, NoopScheduler(), clock: clock);

  bool crashBefore = false, crashAfter = false;
  Completer<void>? hold;
  final started = Completer<void>();
  int memoryCalls = 0;

  @override
  Future<ExecutionReceipt> run(ToolCall c,
      {String? operationId, bool recovering = false, MemoryWriteSource? memorySource}) async {
    if (c.tool != 'save_memory') {
      return super.run(c, operationId: operationId, recovering: recovering, memorySource: memorySource);
    }
    memoryCalls++;
    if (!started.isCompleted) started.complete();
    if (hold != null) await hold!.future;
    if (crashBefore) throw _CrashError();
    final r =
        await super.run(c, operationId: operationId, recovering: recovering, memorySource: memorySource);
    if (crashAfter) throw _CrashError();
    return r;
  }
}

class _World {
  final Database db;
  final OperationJournal journal;
  DateTime now;
  _World(this.db, this.now) : journal = OperationJournal(db);

  /// Judges expiry (plan 1.4) by the world's clock, not the host's.
  late final memory = MemoryRepo(db, clock: () => now);

  late final tools =
      _Tools(TaskRepo(db), ReminderRepo(db), memory, () => now);

  /// A fresh session over the same database, as after an app restart.
  Future<AssistantSession> session() async {
    final s = AssistantSession(
      engine: RuleEngine(clock: () => now),
      tools: tools,
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: TaskRepo(db),
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      operations: journal,
      conversationId: 'memory-temporal',
      clock: () => now,
      interpreter: Interpreter.unified,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  Future<List<Map<String, Object?>>> rows() =>
      db.query('memories', orderBy: 'id');

  Future<List<Map<String, Object?>>> active() =>
      db.query('memories', where: "status = 'active'", orderBy: 'id');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryRepo.add', () {
    test('stores the instant, its offset and the resolved fact date',
        () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      final id = await repo.add('my exam is on Monday', observedAt: _observed);
      final m = (await repo.all()).singleWhere((m) => m.id == id);
      expect(m.observedAtUtc!.millisecondsSinceEpoch,
          _observed.millisecondsSinceEpoch);
      expect(m.observationOffsetMin, _observed.timeZoneOffset.inMinutes);
      expect(m.factDate, '2026-11-02');
      expect(m.dated, 'my exam is on Monday (2 Nov 2026)');
    });

    test('the stored offset, not the device zone, picks the local day',
        () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      // 20:00 UTC Fri 30 Oct is already Sat 31 Oct 01:30 in IST (+5:30)
      // but still Fri 30 Oct 13:00 in PDT (-7:00).
      final instant = DateTime.utc(2026, 10, 30, 20);
      final ist = await repo.add('my exam is tomorrow',
          observedAt: instant, observationOffsetMin: 330);
      final pdt = await repo.add('my flight is tomorrow',
          observedAt: instant, observationOffsetMin: -420);
      final byId = {for (final m in await repo.all()) m.id: m};
      expect(byId[ist]!.factDate, '2026-11-01');
      expect(byId[ist]!.observationOffsetMin, 330);
      expect(byId[pdt]!.factDate, '2026-10-31');
      expect(byId[pdt]!.observationOffsetMin, -420);
      expect(byId[ist]!.observedAtUtc!.isAtSameMomentAs(instant), isTrue);
      expect(byId[pdt]!.observedAtUtc!.isAtSameMomentAs(instant), isTrue);
    });

    test('unresolvable text and a missing observation store no date',
        () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      final vague =
          await repo.add('I went to Goa recently', observedAt: _observed);
      final unseen = await repo.add('my exam is on Monday');
      final byId = {for (final m in await repo.all()) m.id: m};
      expect(byId[vague]!.factDate, isNull);
      expect(byId[vague]!.observedAtUtc, isNotNull);
      expect(byId[unseen]!.observedAtUtc, isNull);
      expect(byId[unseen]!.observationOffsetMin, isNull);
      expect(byId[unseen]!.factDate, isNull);
      expect(byId[unseen]!.dated, 'my exam is on Monday');
    });

    test('a lasting duplicate keeps its first observation', () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      final first =
          await repo.add("my mom's birthday is June 4", observedAt: _observed);
      final again = await repo.add("My mom's birthday is June 4.",
          observedAt: _observed.add(const Duration(days: 4)));
      expect(again, first);
      final m = (await repo.all()).single;
      expect(m.observedAtUtc!.millisecondsSinceEpoch,
          _observed.millisecondsSinceEpoch);
      expect(m.factDate, '--06-04');
      expect(m.expiresAt, isNull);
    });

    test('a time-bound duplicate is re-observed with its later expiry '
        '(plan 1.4 D3)', () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      final first = await repo.add('my exam is on Monday', observedAt: _observed);
      final later = _observed.add(const Duration(days: 1)); // Sat: still 2 Nov
      final again = await repo.add('My exam is on Monday.', observedAt: later);
      expect(again, first);
      final m = (await repo.all()).single;
      expect(m.observedAtUtc!.millisecondsSinceEpoch,
          later.millisecondsSinceEpoch);
      expect(m.factDate, '2026-11-02');
    });

    test('a correction stores its own observation', () async {
      final repo = MemoryRepo(await _db(), clock: () => _observed);
      await repo.add('I drink coffee every morning', observedAt: _observed);
      final id = await repo.addCorrection('I stopped drinking coffee yesterday',
          replaces: 'coffee', observedAt: _observed);
      final m = (await repo.all()).singleWhere((m) => m.id == id);
      expect(m.factDate, '2026-10-29');
      expect(m.observationOffsetMin, _observed.timeZoneOffset.inMinutes);
    });
  });

  test('withFactDate renders absolute and yearly dates, else unchanged', () {
    expect(withFactDate("User's exam is on Monday", '2026-11-02'),
        "User's exam is on Monday (2 Nov 2026)");
    expect(withFactDate("mom's birthday is June 4", '--06-04'),
        "mom's birthday is June 4 (every year on 4 June)");
    expect(withFactDate('likes tea', null), 'likes tea');
    expect(withFactDate('likes tea', 'garbage'), 'likes tea');
    expect(withFactDate('likes tea', '2026-13-01'), 'likes tea');
  });

  group('save_memory executor arguments', () {
    test('integer instant and offset replay the same day in any zone',
        () async {
      final db = await openMigratedV2();
      final memory = MemoryRepo(db);
      final tools = ToolExecutor(
          TaskRepo(db), ReminderRepo(db), memory, NoopScheduler(),
          clock: () => DateTime(2030, 1, 1));
      final instant = DateTime.utc(2026, 10, 30, 20).millisecondsSinceEpoch;
      await tools.run(ToolCall('save_memory', {
        'content': 'my exam is tomorrow',
        'observed_at_utc': instant,
        'observation_offset_min': -420,
      }));
      final row = (await db.query('memories')).single;
      expect(row['observed_at_utc'], instant);
      expect(row['observation_offset_min'], -420);
      expect(row['fact_date'], '2026-10-31');
    });

    test('malformed observation arguments store none rather than guess',
        () async {
      final db = await openMigratedV2();
      final tools = ToolExecutor(
          TaskRepo(db), ReminderRepo(db), MemoryRepo(db), NoopScheduler());
      for (final (i, args) in <Map<String, Object?>>[
        {'observed_at_utc': '1793000000000', 'observation_offset_min': 0},
        {'observed_at_utc': 1793000000000},
        {'observed_at_utc': 1793000000000, 'observation_offset_min': 2000},
      ].indexed) {
        await tools.run(ToolCall(
            'save_memory', {'content': 'my exam is tomorrow $i', ...args}));
      }
      for (final row in await db.query('memories')) {
        expect(row['observed_at_utc'], isNull, reason: '${row['content']}');
        expect(row['observation_offset_min'], isNull);
        expect(row['fact_date'], isNull);
      }
    });
  });

  group('session journal and cancellation', () {
    late _World w;
    setUp(() async {
      w = _World(await _db(), _observed);
    });

    Future<Map<String, Object?>> journaledMemory(String op) async {
      final prior = await w.journal.get(op);
      final action = jsonDecode(prior!.action!) as Map;
      return Map<String, Object?>.from(
          (action['memory'] as Map)['args'] as Map);
    }

    test('a normal turn stores the observation and journals the memory call',
        () async {
      final s = await w.session();
      await s.handle(_said, operationId: 'normal');
      final row = (await w.active()).single;
      expect(row['observed_at_utc'], _observed.millisecondsSinceEpoch);
      expect(row['observation_offset_min'],
          _observed.timeZoneOffset.inMinutes);
      expect(row['fact_date'], _fact);
      expect(row['op_id'], 'normal');
      final args = await journaledMemory('normal');
      expect(args['observed_at_utc'], _observed.millisecondsSinceEpoch);
      expect(args['observation_offset_min'],
          _observed.timeZoneOffset.inMinutes);
    });

    test('crash after the memory write: restart replays, no duplicate',
        () async {
      w.tools.crashAfter = true;
      await expectLater((await w.session()).handle(_said, operationId: 'op-a'),
          throwsA(isA<_CrashError>()));
      expect((await w.journal.get('op-a'))!.status, OperationJournal.executing);
      final original = (await w.rows()).single;

      // Restart days later: startup settles the crashed turn, then the same
      // message is retried.
      w.tools.crashAfter = false;
      w.now = DateTime(2026, 11, 3, 9);
      expect(await w.journal.recoverStale(olderThan: Duration.zero),
          ['op-a']);
      expect((await w.journal.get('op-a'))!.status, OperationJournal.committed);
      final s = await w.session();
      final reply = await s.handle(_said, operationId: 'op-a');

      final rows = await w.rows();
      expect(rows, hasLength(1), reason: 'no duplicate memory: $reply');
      expect(rows.single, original);
      expect(rows.single['fact_date'], _fact);
      expect(await w.db.query('memory_history',
              where: "event = 'add'"),
          hasLength(1));
      expect(s.lastTurn!.receipts.first.status, ReceiptStatus.replayed);
      expect(w.tools.memoryCalls, 2);
      expect(reply, "Okay, I'll remember that through Sat 28 Nov.");
      // The expiry also comes from the journaled observation: midnight
      // after 28 Nov at the offset the fact was said at.
      expect(rows.single['expires_at'],
          DateTime.utc(2026, 11, 29).millisecondsSinceEpoch -
              _observed.timeZoneOffset.inMilliseconds);
    });

    test('crash before the memory write, settled at startup: abandoned, '
        'nothing written or replayed', () async {
      w.tools.crashBefore = true;
      await expectLater((await w.session()).handle(_said, operationId: 'op-f'),
          throwsA(isA<_CrashError>()));
      expect(await w.journal.recoverStale(olderThan: Duration.zero),
          ['op-f']);
      expect((await w.journal.get('op-f'))!.status, OperationJournal.abandoned);
      expect(await w.rows(), isEmpty);
      expect(w.tools.memoryCalls, 1);
    });

    test('crash before the memory write: an in-flight retry replays the '
        'journaled observation, not the retry time', () async {
      w.tools.crashBefore = true;
      await expectLater((await w.session()).handle(_said, operationId: 'op-b'),
          throwsA(isA<_CrashError>()));
      expect(await w.rows(), isEmpty);

      w.tools.crashBefore = false;
      w.now = DateTime(2026, 11, 3, 9); // "yesterday" would be 2 Nov
      final s = await w.session();
      await s.handle(_said, operationId: 'op-b');
      final row = (await w.rows()).single;
      expect(row['observed_at_utc'], _observed.millisecondsSinceEpoch);
      expect(row['observation_offset_min'],
          _observed.timeZoneOffset.inMinutes);
      expect(row['fact_date'], _fact);
      expect(row['op_id'], 'op-b');

      // A third attempt is a pure replay of the stored reply.
      final again = await (await w.session()).handle(_said, operationId: 'op-b');
      expect(again, isNotEmpty);
      expect(await w.rows(), hasLength(1));
    });

    test('a replay is not cancelled midway and still writes exactly once',
        () async {
      w.tools.crashBefore = true;
      await expectLater((await w.session()).handle(_said, operationId: 'op-c'),
          throwsA(isA<_CrashError>()));
      w.tools.crashBefore = false;
      w.now = DateTime(2026, 11, 3, 9);
      final s = await w.session();
      s.onBeforeCommit = () async => s.markCancelled();
      await s.handle(_said, operationId: 'op-c');
      final row = (await w.rows()).single;
      expect(row['observed_at_utc'], _observed.millisecondsSinceEpoch);
      expect(row['fact_date'], _fact);
    });

    test('cancel before commit writes no memory and journals no action',
        () async {
      final s = await w.session();
      final gate = Completer<void>();
      final reached = Completer<void>();
      s.onBeforeCommit = () {
        reached.complete();
        return gate.future;
      };
      final turn = s.handle(_said, operationId: 'op-d');
      await reached.future.timeout(_timeout);
      final cancelling = s.cancel();
      gate.complete();
      await cancelling.timeout(_timeout);
      expect(await turn.timeout(_timeout), isEmpty);
      expect(await w.rows(), isEmpty);
      expect(w.tools.memoryCalls, 0);
      final op = (await w.journal.get('op-d'))!;
      expect(op.status, OperationJournal.abandoned);
      expect(op.action, isNull);
      // Startup recovery leaves the abandoned turn alone.
      expect(await w.journal.recoverStale(olderThan: Duration.zero), isEmpty);
    });

    test('cancel while the memory write runs lets it finish once', () async {
      final s = await w.session();
      w.tools.hold = Completer<void>();
      final turn = s.handle(_said, operationId: 'op-e');
      await w.tools.started.future.timeout(_timeout);
      final cancelling = s.cancel();
      w.tools.hold!.complete();
      await cancelling.timeout(_timeout);
      await turn.timeout(_timeout);
      final rows = await w.rows();
      expect(rows, hasLength(1));
      expect(rows.single['observed_at_utc'], _observed.millisecondsSinceEpoch);
      expect((await w.journal.get('op-e'))!.status,
          isIn([OperationJournal.replied, OperationJournal.committed]));

      // Resending the same turn replays the reply, writes nothing.
      w.tools.hold = null;
      w.now = DateTime(2026, 11, 3, 9);
      await (await w.session()).handle(_said, operationId: 'op-e');
      expect(await w.rows(), hasLength(1));
      expect(w.tools.memoryCalls, 1);
    });
  });
}
