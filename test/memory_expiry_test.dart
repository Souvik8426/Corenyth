import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/temporal.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/backup_fixture.dart';
import 'support/v2_db.dart';

/// Plan 1.4 expiry regressions:
/// D1 an old historical fact must not be stored already expired;
/// D2 a backup restore must not give an expiring row a preference slot;
/// D3 restating an expiring fact must not keep its first, stale expiry.
/// Plus the temporal window, timezone, Sunday, month-rollover, replay and
/// backup boundaries.

const _ist = 330, _pdt = -420;

/// The instant a local midnight [y]-[m]-[d] starts at UTC offset [offset].
int _midnight(int y, int m, int d, int offset) =>
    DateTime.utc(y, m, d).millisecondsSinceEpoch - offset * 60000;

/// [memoryExpiresAt] for [content] said at UTC [utc] in [offset].
int? _expiry(String content, DateTime utc, int offset) =>
    memoryExpiresAt(content, observedAt: utc, observationOffsetMin: offset);

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

Future<Map<String, Object?>> _row(Database db, int id) async =>
    (await db.query('memories', where: 'id = ?', whereArgs: [id])).single;

class _CrashError implements Exception {}

class _Tools extends ToolExecutor {
  _Tools(TaskRepo tasks, ReminderRepo reminders, MemoryRepo memory,
      DateTime Function() clock)
      : super(tasks, reminders, memory, NoopScheduler(), clock: clock);

  bool crashAfter = false;

  @override
  Future<ExecutionReceipt> run(ToolCall c,
      {String? operationId, bool recovering = false, MemoryWriteSource? memorySource}) async {
    final r =
        await super.run(c, operationId: operationId, recovering: recovering, memorySource: memorySource);
    if (c.tool == 'save_memory' && crashAfter) throw _CrashError();
    return r;
  }
}

class _World {
  final Database db;
  final OperationJournal journal;
  DateTime now;
  _World(this.db, this.now) : journal = OperationJournal(db);

  late final memory = MemoryRepo(db, clock: () => now);
  late final tools = _Tools(TaskRepo(db), ReminderRepo(db), memory, () => now);

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
      conversationId: 'memory-expiry',
      clock: () => now,
      interpreter: Interpreter.unified,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  Future<List<Map<String, Object?>>> rows() =>
      db.query('memories', orderBy: 'id');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('factExpiresAt / memoryExpiresAt windows and time zones', () {
    test('IST: "tomorrow" said after local midnight ends at the IST midnight '
        'after its day', () {
      // 30 Oct 20:00 UTC = Sat 31 Oct 01:30 IST, so tomorrow is 1 Nov.
      final at = DateTime.utc(2026, 10, 30, 20);
      expect(_expiry('my exam is tomorrow', at, _ist),
          _midnight(2026, 11, 2, _ist));
    });

    test('PDT: "today" said 23:30 local ends half an hour later', () {
      // 31 Oct 06:30 UTC = Fri 30 Oct 23:30 PDT.
      final at = DateTime.utc(2026, 10, 31, 6, 30);
      final e = _expiry("I'm free today", at, _pdt);
      expect(e, _midnight(2026, 10, 31, _pdt));
      expect(e! - at.millisecondsSinceEpoch, 30 * 60000);
      // The same instant in IST is already Sat 31 Oct midday.
      expect(_expiry("I'm free today", at, _ist),
          _midnight(2026, 11, 1, _ist));
    });

    test('a later DST change does not move the stored local midnight', () {
      // US DST ends 1 Nov 2026; the expiry stays at the PDT offset said at.
      final at = DateTime.utc(2026, 10, 31, 18); // Sat 11:00 PDT
      expect(_expiry("I'm in Goa next week", at, _pdt),
          _midnight(2026, 11, 9, _pdt));
    });

    test('Sunday edge: "this week" said late Sunday ends that midnight; '
        'said just after Monday starts it runs a full week', () {
      final sunday = DateTime.utc(2026, 11, 1, 16, 30); // Sun 22:00 IST
      expect(_expiry("I'm in Goa this week", sunday, _ist),
          _midnight(2026, 11, 2, _ist));
      final monday = DateTime.utc(2026, 11, 1, 19); // Mon 2 Nov 00:30 IST
      expect(_expiry("I'm in Goa this week", monday, _ist),
          _midnight(2026, 11, 9, _ist));
      // "next week" on Sunday is the following Monday-Sunday.
      expect(_expiry("I'm in Goa next week", sunday, _ist),
          _midnight(2026, 11, 9, _ist));
    });

    test('month and year rollover', () {
      final dec = DateTime.utc(2026, 12, 15, 6);
      expect(_expiry("I'm in Goa next month", dec, _ist),
          _midnight(2027, 2, 1, _ist));
      // 31 Dec 23:00 IST: tomorrow is 1 Jan 2027.
      final eve = DateTime.utc(2026, 12, 31, 17, 30);
      expect(_expiry('my exam is tomorrow', eve, _ist),
          _midnight(2027, 1, 2, _ist));
      // 31 Jan + 30 days crosses February.
      expect(
          factExpiresAt('I met Priya on 31 January 2027',
              observedUtcMs: DateTime.utc(2027, 2, 1).millisecondsSinceEpoch,
              offsetMin: 0,
              factDate: '2027-01-31',
              temporary: false),
          _midnight(2027, 3, 3, 0));
    });

    test('an unresolved short-lived window lasts 7 days; durable, yearly '
        'and slot facts never expire', () {
      final at = DateTime.utc(2026, 10, 30, 8);
      expect(_expiry("I'm busy at 5pm", at, _ist),
          at.millisecondsSinceEpoch + const Duration(days: 7).inMilliseconds);
      expect(_expiry('I usually run every morning', at, _ist), isNull);
      expect(_expiry("my mom's birthday is June 4", at, _ist), isNull);
      expect(_expiry('I live in Pune', at, _ist), isNull);
    });

    test('pure: the same integers give the same expiry on any host day', () {
      final at = DateTime.utc(2026, 10, 30, 20);
      final a = _expiry('my exam is next Monday', at, _ist);
      final b = _expiry('my exam is next Monday', at.toLocal(), _ist);
      expect(a, isNotNull);
      expect(a, b);
    });
  });

  group('D1: old historical facts', () {
    final at = DateTime.utc(2026, 10, 30, 8);

    test('a dated fact long in the past never expires', () {
      expect(_expiry('I graduated on 2 June 2020', at, _ist), isNull);
      expect(_expiry('I moved to Pune on 2019-03-01', at, _ist), isNull);
      expect(
          factExpiresAt('my exam was on Monday',
              observedUtcMs: at.millisecondsSinceEpoch,
              offsetMin: _ist,
              factDate: '2020-06-01',
              temporary: true),
          isNull,
          reason: 'a long-past short-lived day is history, not expired');
    });

    test('birth dates and anniversaries with a year never expire', () {
      final soon = DateTime.utc(1990, 6, 5);
      expect(_expiry('I was born on 4 June 1990', soon, 0), isNull);
      expect(_expiry('our anniversary was on 2026-10-20', at, _ist), isNull);
    });

    test('a recent one-off fact still ends 30 days after its day, and the '
        'boundary is exclusive', () {
      // 29 Oct + 30 days: the midnight after 28 Nov.
      expect(_expiry('I met Priya yesterday', at, _ist),
          _midnight(2026, 11, 29, _ist));
      // Said exactly at the 30-day end: already over, so lasting.
      final end = _midnight(2026, 11, 29, _ist);
      expect(
          factExpiresAt('I met Priya on 2026-10-29',
              observedUtcMs: end,
              offsetMin: _ist,
              factDate: '2026-10-29',
              temporary: false),
          isNull);
      expect(
          factExpiresAt('I met Priya on 2026-10-29',
              observedUtcMs: end - 1,
              offsetMin: _ist,
              factDate: '2026-10-29',
              temporary: false),
          end);
    });

    test('MemoryRepo stores the historical fact visibly, without expiry',
        () async {
      final db = await _db();
      final repo = MemoryRepo(db, clock: () => at);
      final id = await repo.add('I graduated on 2 June 2020',
          observedAt: at, observationOffsetMin: _ist);
      final row = await _row(db, id);
      expect(row['fact_date'], '2020-06-02');
      expect(row['expires_at'], isNull);
      expect([for (final m in await repo.all()) m.id], [id]);
      expect(await repo.purgeDeleted(), 0);
      expect((await _row(db, id))['status'], 'active');
    });
  });

  group('D3: repeated expiring facts', () {
    test('restating re-observes the row: later expiry and fact day', () async {
      final db = await _db();
      var now = DateTime.utc(2026, 10, 30, 8); // Fri 13:30 IST
      final repo = MemoryRepo(db, clock: () => now);
      final id = await repo.add('my exam is tomorrow',
          observedAt: now, observationOffsetMin: _ist);
      expect((await _row(db, id))['expires_at'], _midnight(2026, 11, 1, _ist));

      now = DateTime.utc(2026, 10, 31, 8); // Sat: tomorrow is now Sunday
      final again = await repo.add('My exam is tomorrow.',
          observedAt: now, observationOffsetMin: _ist);
      expect(again, id, reason: 'still a duplicate, not a second row');
      final row = await _row(db, id);
      expect(row['expires_at'], _midnight(2026, 11, 2, _ist));
      expect(row['fact_date'], '2026-11-01');
      expect(row['observed_at_utc'], now.millisecondsSinceEpoch);
      expect(row['importance'], closeTo(0.6, 1e-9));

      // Visible all Sunday, gone at the Sunday midnight.
      now = DateTime.utc(2026, 11, 1, 18, 29);
      expect([for (final m in await repo.all()) m.id], [id]);
      now = DateTime.utc(2026, 11, 1, 18, 30);
      expect(await repo.all(), isEmpty);
    });

    test('an earlier or identical restatement keeps the stored expiry',
        () async {
      final db = await _db();
      final first = DateTime.utc(2026, 10, 31, 8);
      var now = first;
      final repo = MemoryRepo(db, clock: () => now);
      final id = await repo.add('my exam is tomorrow',
          observedAt: first, observationOffsetMin: _ist);
      final before = await _row(db, id);

      // A late, earlier observation (e.g. a delayed retry) cannot shorten it.
      await repo.add('my exam is tomorrow',
          observedAt: DateTime.utc(2026, 10, 30, 8),
          observationOffsetMin: _ist);
      var row = await _row(db, id);
      expect(row['expires_at'], before['expires_at']);
      expect(row['fact_date'], before['fact_date']);
      expect(row['observed_at_utc'], before['observed_at_utc']);

      // The same observation again is idempotent for the expiry.
      await repo.add('my exam is tomorrow',
          observedAt: first, observationOffsetMin: _ist);
      row = await _row(db, id);
      expect(row['expires_at'], before['expires_at']);
      expect(row['observed_at_utc'], before['observed_at_utc']);
    });

    test('a lasting row stays lasting; an unobserved restatement changes no '
        'expiry; an expired row is re-added fresh', () async {
      final db = await _db();
      var now = DateTime.utc(2026, 10, 30, 8);
      final repo = MemoryRepo(db, clock: () => now);
      final lasting = await repo.add('I graduated on 2 June 2020',
          observedAt: now, observationOffsetMin: _ist);
      await repo.add('I graduated on 2 June 2020',
          observedAt: now.add(const Duration(days: 1)),
          observationOffsetMin: _ist);
      expect((await _row(db, lasting))['expires_at'], isNull);

      final temp = await repo.add('my exam is tomorrow',
          observedAt: now, observationOffsetMin: _ist);
      final e = (await _row(db, temp))['expires_at'];
      expect(await repo.add('my exam is tomorrow'), temp);
      expect((await _row(db, temp))['expires_at'], e);

      now = DateTime.utc(2026, 11, 2);
      final fresh = await repo.add('my exam is tomorrow',
          observedAt: now, observationOffsetMin: _ist);
      expect(fresh, isNot(temp));
      expect((await _row(db, fresh))['expires_at'],
          _midnight(2026, 11, 4, _ist));
    });
  });

  group('session: "remember my exam is next Monday"', () {
    // Fri 30 Oct 2026 14:00 on the host; offsets follow the host zone.
    final observed = DateTime(2026, 10, 30, 14);
    final offset = observed.timeZoneOffset.inMinutes;

    test('stores the Monday, replies with it, and is gone after Monday',
        () async {
      final w = _World(await _db(), observed);
      final s = await w.session();
      final reply = await s.handle('remember my exam is next Monday',
          operationId: 'exam');
      expect(reply, "Okay, I'll remember that through Mon 2 Nov.");
      final row = (await w.rows()).single;
      expect(row['fact_date'], '2026-11-02');
      expect(row['expires_at'], _midnight(2026, 11, 3, offset));
      expect(row['subject_key'], isNull);

      w.now = DateTime.fromMillisecondsSinceEpoch(
          _midnight(2026, 11, 3, offset) - 1);
      expect(await w.memory.all(), hasLength(1));
      w.now = DateTime.fromMillisecondsSinceEpoch(
          _midnight(2026, 11, 3, offset));
      expect(await w.memory.all(), isEmpty);
      expect(await w.memory.search('exam'), isEmpty);
    });

    test('implicit plans and obligations are still not stored', () async {
      final w = _World(await _db(), observed);
      final s = await w.session();
      await s.handle('my exam is next Monday', operationId: 'implicit');
      final reply = await s.handle('remember I have to call mom tomorrow',
          operationId: 'obligation');
      expect(await w.rows(), isEmpty, reason: reply);
    });

    test('replay of a restated fact keeps the journaled (second) '
        'observation, not the restart time', () async {
      final w = _World(await _db(), observed);
      await (await w.session())
          .handle('remember my exam is tomorrow', operationId: 'first');
      final id = (await w.rows()).single['id'];

      // Restated the next day, crashing after the write.
      w.now = DateTime(2026, 10, 31, 9);
      w.tools.crashAfter = true;
      await expectLater(
          (await w.session())
              .handle('remember my exam is tomorrow', operationId: 'second'),
          throwsA(isA<_CrashError>()));
      final written = (await w.rows()).single;
      expect(written['id'], id);
      expect(written['expires_at'], _midnight(2026, 11, 2, offset));

      // Restart days later and retry the same message.
      w.tools.crashAfter = false;
      w.now = DateTime(2026, 11, 1, 10);
      await w.journal.recoverStale(olderThan: Duration.zero);
      await (await w.session())
          .handle('remember my exam is tomorrow', operationId: 'second');
      final rows = await w.rows();
      expect(rows, hasLength(1));
      expect(rows.single, written);
    });
  });

  group('D2: backup restore and expiry', () {
    test('a restored expiring row takes no slot, so the lasting fact in '
        'that slot still restores', () async {
      final db = await _db();
      final h = BackupHarness(db, await tempFolder());
      final at = DateTime.utc(2026, 10, 30, 8); // Fri IST
      final repo = MemoryRepo(db, clock: () => at);
      final home = await repo.add('I live in Pune',
          observedAt: at, observationOffsetMin: _ist);
      final trip = await repo.add('I live in Goa this week',
          observedAt: at, observationOffsetMin: _ist);
      final tripRow = await _row(db, trip);
      expect(tripRow['expires_at'], _midnight(2026, 11, 2, _ist));
      expect(tripRow['subject_key'], isNull);
      expect((await _row(db, home))['status'], 'active',
          reason: 'an expiring fact supersedes nothing');
      await repo.delete(home);
      final before = await rowsOf(db, 'memories');

      final preview = await h.service.readAndCheck(await h.export());
      await h.service.importBackup(preview);
      expect(await rowsOf(db, 'memories'), before,
          reason: 'expires_at and null slot keys round-trip unchanged');
      expect((await _row(db, trip))['attribute_key'], isNull);
      expect((await repo.restore(home)).status, RestoreStatus.restored);
    });

    test('planner example: "meeting this afternoon" restored keeps no '
        'meeting-time slot; the lasting preference restores and survives '
        'the expiry', () async {
      final db = await _db();
      final h = BackupHarness(db, await tempFolder());
      var now = DateTime.utc(2026, 10, 30, 4); // Fri 09:30 IST
      final repo = MemoryRepo(db, clock: () => now);
      final pref = await repo.add('User prefers meetings in the afternoon');
      expect((await _row(db, pref))['attribute_key'], 'pref:meeting_time');
      final meeting = await repo.add('User has a meeting this afternoon',
          observedAt: now, observationOffsetMin: _ist);
      expect((await _row(db, meeting))['expires_at'],
          _midnight(2026, 10, 31, _ist));
      expect((await _row(db, pref))['status'], 'active');
      await repo.delete(pref);

      await h.service.importBackup(
          await h.service.readAndCheck(await h.export()));
      expect((await _row(db, meeting))['attribute_key'], isNull);
      expect((await repo.restore(pref)).status, RestoreStatus.restored);
      now = DateTime.utc(2026, 10, 31);
      expect([for (final m in await repo.all()) m.id], [pref]);
    });

    test('lasting rows still get their slot keys back after a restore',
        () async {
      final db = await _db();
      final h = BackupHarness(db, await tempFolder());
      final repo = MemoryRepo(db);
      final id = await repo.add('I live in Pune');
      final preview = await h.service.readAndCheck(await h.export());
      await h.service.importBackup(preview);
      expect((await _row(db, id))['attribute_key'], 'location:residence');
    });

    test('an expired active row restores hidden and is retired by purge',
        () async {
      final db = await _db();
      final h = BackupHarness(db, await tempFolder());
      var now = DateTime.utc(2026, 10, 30, 8);
      final repo = MemoryRepo(db, clock: () => now);
      final id = await repo.add('my exam is tomorrow',
          observedAt: now, observationOffsetMin: _ist);
      final preview = await h.service.readAndCheck(await h.export());

      now = DateTime.utc(2026, 11, 5);
      await h.service.importBackup(preview);
      final row = await _row(db, id);
      expect(row['expires_at'], _midnight(2026, 11, 1, _ist));
      expect(row['status'], 'active');
      expect(await repo.all(), isEmpty);
      expect(await repo.purgeDeleted(), 0);
      expect((await _row(db, id))['status'], 'deleted');
    });
  });
}
