import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/assistant/semantic.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingScheduler extends NoopScheduler {
  final scheduled = <Reminder>[];
  @override
  Future<void> schedule(Reminder r) async => scheduled.add(r);
}

class _SlowOptionalEngine extends LlmEngine {
  bool optionalCalled = false;
  Future<void>? slowFuture;

  @override
  String get name => 'slow-engine';

  @override
  Future<bool> load() async => true;

  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async => '';

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    if (p.moodOnly) {
      optionalCalled = true;
      if (slowFuture != null) await slowFuture;
      onRaw?.call(_envelope);
      return _envelope;
    }
    return '';
  }
}

const _envelope =
    '{"emotion":{"mood":"happy","intensity":0.80,"confidence":0.90}}';

/// Phase 0.2 fake: records every prompt; the mood-only job streams
/// [moodChunks] (cumulative) after [hold]; plan prompts answer as chat.
class _MoodEngine extends LlmEngine {
  final prompts = <Prompt>[];
  final optionalPrompts = <Prompt>[];
  List<String> moodChunks = const [_envelope];
  Completer<void>? hold;
  final optionalStarted = Completer<void>();

  @override
  String get name => 'mood-engine';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) => completeStreaming(p);

  @override
  Future<String> completeOptional(Prompt p,
      {void Function(String raw)? onRaw}) {
    optionalPrompts.add(p);
    return super.completeOptional(p, onRaw: onRaw);
  }

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    prompts.add(p);
    if (p.moodOnly) {
      if (!optionalStarted.isCompleted) optionalStarted.complete();
      await hold?.future;
      for (final c in moodChunks) {
        onRaw?.call(c);
      }
      return moodChunks.isEmpty ? '' : moodChunks.last;
    }
    const plan = '{"emotion":{"mood":"calm","intensity":0.25,'
        '"confidence":0.80},"intent":"chat","reply":"Doing great!"}';
    onRaw?.call(plan);
    return plan;
  }
}

class _CountingMoods extends MoodRepo {
  _CountingMoods(super.db);
  var saves = 0;
  @override
  Future<void> save({
    required int messageId,
    required String chatId,
    required String source,
    String? mood,
    double intensity = 0.25,
    double? confidence,
  }) {
    saves++;
    return super.save(
        messageId: messageId,
        chatId: chatId,
        source: source,
        mood: mood,
        intensity: intensity,
        confidence: confidence);
  }
}

class _MoodHarness {
  final Database db;
  final Directory dir;
  final AssistantSession session;
  final _CountingMoods moods;
  final ProfileRepo profile;
  final moodEvents = <TurnMood>[];
  _MoodHarness(this.db, this.dir, this.session, this.moods, this.profile);

  static Future<_MoodHarness> open(_MoodEngine engine,
      {UserProfile? user, Interpreter? interpreter}) async {
    final dir = await Directory.systemTemp.createTemp('corenyth_mood_');
    final db = await openAppDb(path: p.join(dir.path, 'mood.db'));
    final tasks = TaskRepo(db);
    final memory = MemoryRepo(db);
    final profile = ProfileRepo(db);
    if (user != null) await profile.save(user);
    final moods = _CountingMoods(db);
    final session = AssistantSession(
      engine: engine,
      tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
          clock: DateTime.now),
      memory: memory,
      profile: profile,
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      operations: OperationJournal(db),
      moods: moods,
      interpreter: interpreter,
    );
    await session.start();
    return _MoodHarness(db, dir, session, moods, profile);
  }

  Future<String> handle(String text) =>
      session.handle(text, onMood: moodEvents.add);

  /// A rule-answered turn (no model call), so the optional mood job runs.
  Future<String> ruleTurn() async {
    final tasks = TaskRepo(db);
    if ((await tasks.list()).isEmpty) await tasks.create('buy milk');
    return handle('did I add buy milk?');
  }

  Future<void> dispose() async {
    await session.close();
    await db.close();
    await dir.delete(recursive: true);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('P6 Memory indexing, schema v10 and migration', () {
    test('v10 migration adds hash, slot columns, indices, and backfills legacy memories', () async {
      final dir = await Directory.systemTemp.createTemp('corenyth_v10_mig_');
      final dbPath = p.join(dir.path, 'v9.db');

      // Create v9 schema manually
      final v9Db = await openDatabase(
        dbPath,
        version: 9,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE memories(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'fact',
            importance REAL NOT NULL DEFAULT 0.5,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            last_accessed_at INTEGER, embedding BLOB,
            op_id TEXT, source TEXT, status TEXT NOT NULL DEFAULT 'active',
            superseded_by INTEGER)''');
          await db.execute(
              'CREATE VIRTUAL TABLE memories_fts USING fts4(content, tokenize=unicode61)');
          await db.execute('''CREATE TABLE conversations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
            created_at INTEGER NOT NULL, task_id INTEGER, kind TEXT)''');
          await db.execute('''CREATE TABLE tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL, notes TEXT, status TEXT NOT NULL DEFAULT 'pending',
            priority INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, due_at INTEGER, recurrence TEXT,
            op_id TEXT)''');
          await db.execute('''CREATE TABLE reminders(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL, trigger_at INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1, task_id INTEGER,
            sync TEXT, op_id TEXT)''');
          await db.execute('''CREATE TABLE operations(
            op_id TEXT PRIMARY KEY, chat_id TEXT NOT NULL,
            text_hash TEXT NOT NULL, status TEXT NOT NULL,
            action TEXT, receipt TEXT,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
          await db.execute('''CREATE TABLE message_moods(
            message_id INTEGER PRIMARY KEY, chat_id TEXT NOT NULL,
            mood TEXT, intensity REAL NOT NULL DEFAULT 0.25,
            confidence REAL, source TEXT NOT NULL, created_at INTEGER NOT NULL)''');
        },
      );

      // Seed with legacy memories without hash or slots
      await v9Db.insert('memories', {
        'content': 'User likes green tea',
        'category': 'preference',
        'importance': 0.6,
        'created_at': 1000,
        'updated_at': 1000,
        'status': 'active',
      });
      await v9Db.insert('memories', {
        'content': 'User lives in Bangalore',
        'category': 'fact',
        'importance': 0.5,
        'created_at': 2000,
        'updated_at': 2000,
        'status': 'active',
      });
      await v9Db.close();

      // Open through openAppDb to trigger upgrade to v10
      final v10Db = await openAppDb(path: dbPath);
      expect(await v10Db.getVersion(), dbVersion);
      expect(dbVersion, 13);
      final v12Tables = (await v10Db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table'"))
          .map((r) => r['name']);
      expect(v12Tables, containsAll(['extraction_state', 'extraction_sources']));

      // Verify new columns exist
      final columns = (await v10Db.rawQuery('PRAGMA table_info(memories)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(columns, containsAll([
        'content_hash',
        'subject_key',
        'attribute_key',
        'observed_at_utc',
        'observation_offset_min',
        'fact_date',
      ]));

      // Verify indices exist
      final indices = (await v10Db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'memories'"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(indices, containsAll(['memories_status_hash', 'memories_slot']));

      // Verify deterministic backfill
      final rows = await v10Db.query('memories', orderBy: 'id ASC');
      expect(rows.length, 2);

      final row1 = rows[0];
      final expectedHash1 =
          sha256.convert(utf8.encode('user likes green tea')).toString();
      expect(row1['content_hash'], expectedHash1);
      expect(row1['subject_key'], 'user');
      expect(row1['attribute_key'], 'pref:drink:kind');
      expect(row1['observed_at_utc'], isNull);

      final row2 = rows[1];
      final expectedHash2 =
          sha256.convert(utf8.encode('user lives in bangalore')).toString();
      expect(row2['content_hash'], expectedHash2);
      expect(row2['subject_key'], 'user');
      expect(row2['attribute_key'], 'location:residence');

      // Now add new memory using MemoryRepo and verify fast dedupe / superseding
      final repo = MemoryRepo(v10Db);
      final newId = await repo.add('I like coffee now, not green tea',
          category: 'preference');

      // Prior tea preference must be superseded
      final teaRow = (await v10Db.query('memories',
          where: "content = 'User likes green tea'")).single;
      expect(teaRow['status'], 'superseded');
      expect(teaRow['superseded_by'], newId);

      // Active coffee preference must be present with indexed slot
      final coffeeRow = (await v10Db.query('memories',
          where: "content LIKE '%coffee%'")).single;
      expect(coffeeRow['status'], 'active');
      expect(coffeeRow['subject_key'], 'user');
      expect(coffeeRow['attribute_key'], 'pref:drink:kind');

      await v10Db.close();
      await dir.delete(recursive: true);
    });
  });

  group('P3 Foreground completion order and independent optional mood', () {
    test('foreground reply settles without awaiting optional mood', () async {
      final dir = await Directory.systemTemp.createTemp('corenyth_p3_');
      final db = await openAppDb(path: p.join(dir.path, 'p3.db'));
      final tasks = TaskRepo(db);
      final reminders = ReminderRepo(db);
      final memory = MemoryRepo(db);
      final conversations = ConversationRepo(db);
      final operations = OperationJournal(db);
      final profile = ProfileRepo(db);
      final moods = MoodRepo(db);
      final scheduler = _RecordingScheduler();
      final engine = _SlowOptionalEngine();

      // Block optional mood generation with an unsettled future
      final slow = Completer<void>();
      engine.slowFuture = slow.future;

      final session = AssistantSession(
        engine: engine,
        tools: ToolExecutor(tasks, reminders, memory, scheduler, clock: DateTime.now),
        memory: memory,
        profile: profile,
        taskRepo: tasks,
        conversations: conversations,
        operations: operations,
        moods: moods,
      );
      await session.start();

      String receivedReply = '';
      final stopwatch = Stopwatch()..start();
      final reply = await session.handle('add task buy milk', onText: (t) {
        receivedReply = t;
      });

      // Foreground turn completes immediately
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      expect(reply, contains('buy milk'));
      expect(receivedReply, reply);

      // Assistant message and operation journal are committed before settlement
      final lastMsg = (await conversations.recent(session.id, n: 1)).single;
      expect(lastMsg.role, 'assistant');
      expect(lastMsg.content, reply);

      final op = await operations.get(session.lastOperationId!);
      expect(op, isNotNull);
      expect(op!.status, OperationJournal.replied);

      // Release optional mood
      slow.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await session.close();
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  group('0.2 mood job: plan prompt, mood-only grammar, accept once', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('M1: repeated complete envelopes are accepted and saved once',
        () async {
      final engine = _MoodEngine()
        ..moodChunks = [
          for (var i = 0; i < 5; i++) '$_envelope${' ' * i}',
        ];
      final h = await _MoodHarness.open(engine);
      addTearDown(h.dispose);
      expect(await h.ruleTurn(), contains('buy milk'));
      await h.session.lastOptionalMoodJob;
      expect(engine.optionalPrompts, hasLength(1));
      expect(h.moods.saves, 1);
      expect(h.moodEvents, hasLength(1));
      expect(h.moodEvents.single.source, 'model:mood');
      final rows = await h.moods.rowsForChat(h.session.id);
      expect(rows, hasLength(1));
      expect(rows.values.single['source'], 'model:mood');
      expect(rows.values.single['mood'], 'happy');
      expect(h.session.lastDiagnostics['mood'], 'happy(model:mood)');
      expect(h.session.lastDiagnostics['model_calls'], '0p0r+mood');
    });

    test('M2: a preempted job never overwrites the next turn diagnostics',
        () async {
      final engine = _MoodEngine()..hold = Completer<void>();
      final h = await _MoodHarness.open(engine);
      addTearDown(h.dispose);
      await h.ruleTurn();
      final first = h.session.lastOptionalMoodJob!;
      await engine.optionalStarted.future;
      expect(await h.handle('2+2'), contains('4'));
      final second = h.session.lastDiagnostics;
      engine.hold!.complete();
      await first;
      expect(h.session.lastDiagnostics, second);
      expect(h.session.lastDiagnostics['mood'], isNot('happy(model:mood)'));
      expect(h.moods.saves, 0);
      expect(h.moodEvents, isEmpty);
    });

    test('M3: no envelope means mood none and nothing saved', () async {
      final engine = _MoodEngine()..moodChunks = ['{"emo', '{"emotion":{'];
      final h = await _MoodHarness.open(engine);
      addTearDown(h.dispose);
      await h.ruleTurn();
      await h.session.lastOptionalMoodJob;
      expect(engine.optionalPrompts, hasLength(1));
      expect(h.session.lastDiagnostics['mood'], 'none');
      expect(h.moods.saves, 0);
      expect(h.moodEvents, isEmpty);
      expect(await h.moods.rowsForChat(h.session.id), isEmpty);
    });

    for (final mode in Interpreter.values) {
      test('M4: mood prompt reuses the coordinator plan system block ($mode)',
          () async {
        final engine = _MoodEngine();
        final h = await _MoodHarness.open(engine,
            user: const UserProfile(name: 'Asha', tone: 'calm'),
            interpreter: mode);
        addTearDown(h.dispose);
        await h.handle('hey how is it going');
        final plan = engine.prompts.singleWhere((p) => !p.moodOnly);
        expect(plan.kind, PromptKind.plan);
        await h.ruleTurn();
        await h.session.lastOptionalMoodJob;
        final mood = engine.optionalPrompts.single;
        expect(mood.moodOnly, isTrue);
        expect(mood.kind, PromptKind.plan);
        expect(mood.contract, plan.contract);
        String system(Prompt p) {
          final r = p.render();
          return r.substring(0, r.indexOf('<|im_end|>'));
        }

        expect(system(mood), system(plan));
        expect(system(mood), contains('Asha'));
        expect(mood.render(), contains('Current tasks:\n(none)'));
        expect(
            mood.contract,
            mode == Interpreter.unified
                ? planContractV2
                : promptContractVersion);
      });
    }

    test('M5: mood-only grammar ends after the envelope', () {
      final p = Prompt(PromptKind.plan, 'hi', moodOnly: true);
      expect(p.grammar, startsWith(r'root ::= "{\"emotion\":" emotion "}"'));
      expect(p.grammar, Prompt.moodOnlyGrammar);
      expect(p.grammar, contains(emotionGrammar));
      // Prompt bytes are unchanged; every trimmed candidate keeps the flag.
      final now = DateTime(2099, 1, 1, 9);
      expect(
          p.render(now: now), Prompt(PromptKind.plan, 'hi').render(now: now));
      expect(Prompt(PromptKind.plan, 'hi').grammar, isNot(p.grammar));
    });

    test('M5: native request is capped at 32 tokens with the mood grammar',
        () async {
      const channel = MethodChannel('assistant/llm');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return _envelope;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final engine = LlamaChannelEngine('model');
      await engine.completeOptional(
          Prompt(PromptKind.plan, 'hi', moodOnly: true),
          onRaw: (_) {});
      await engine.complete(Prompt(PromptKind.plan, 'hi'));
      expect(calls[0].arguments['maxTokens'], 32);
      expect(calls[0].arguments['grammar'], Prompt.moodOnlyGrammar);
      expect(calls[1].arguments['maxTokens'], 140);
    });
  });
}
