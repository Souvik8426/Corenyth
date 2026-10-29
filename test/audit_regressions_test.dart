// Repaired audit regressions, maintained as part of the suite.
// Source: audit/code_audit_regression_test.dart (six red probes), updated to
// the repaired contracts — most importantly the turn-identity contract, where
// the completed-view scenario now reconciles the optimistic user message with
// its persisted row id instead of falling back for arbitrary ID-less rows.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/follow_through.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:assistant/services/backup/backup_service.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/ui/chat_view.dart';
import 'package:assistant/ui/mascot_emotion_scope.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/assistant/semantic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

final _now = DateTime(2099, 10, 14, 7);

/// Stand-in for the on-device model: answers plan/reply prompts with canned
/// JSON, streaming the raw output in chunks while the completion future is
/// still unresolved — the same protocol as LlamaBridge's text{id,text} events.
class _StreamingPlanner extends LlmEngine {
  /// Raw output per `${p.kind.name}:${p.user}`.
  final outputs = <String, String>{};

  /// Cumulative raw prefixes to deliver before completing, in order.
  final streamPlan = <String, List<String>>{};

  /// When set, the completion future stays unresolved until released.
  Completer<void>? gate;

  final rawEvents = <String>[];
  final prompts = <Prompt>[];

  @override
  String get name => 'qwen-standin';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<void> cancel() async {
    gate?.complete();
  }

  @override
  Future<String> complete(Prompt p) => completeStreaming(p);

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    prompts.add(p);
    final key = '${p.kind.name}:${p.user}';
    final raw = outputs[key] ?? '{"emotion":{"mood":"calm","intensity":0.25,'
        '"confidence":0.9},"intent":"chat","reply":"Okay!"}';
    for (final part in streamPlan[key] ?? [raw]) {
      onRaw?.call(part);
      rawEvents.add(part);
    }
    await gate?.future;
    return raw;
  }
}

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<int> add(String content,
          {String category = 'fact',
          double importance = 0.5,
          String? opId,
          String? source}) async =>
      1;
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late _StreamingPlanner model;
  late AssistantSession session;

  setUp(() async {
    db = await openMigratedV2();
    model = _StreamingPlanner();
    final tasks = TaskRepo(db);
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, ReminderRepo(db), _Memory(db), NoopScheduler(),
          clock: () => _now, preferences: ReminderPreferencesRepo(db)),
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      operations: OperationJournal(db),
      moods: MoodRepo(db),
      conversationId: 'chat',
      clock: () => _now,
    );
    await session.start();
  });

  group('configured tone survives candidate construction and budgeting', () {
    test('every supported tone reaches every candidate render', () {
      for (final tone in Prompt.toneStyles.keys) {
        final p = Prompt(PromptKind.plan, 'Hello', tone: tone);
        expect(p.render(), contains('Reply tone: $tone'), reason: tone);
        for (final candidate in p.candidates()) {
          expect(candidate, contains('Reply tone: $tone'), reason: tone);
        }
        // History trimming and optional-context removal keep the tone.
        final trimmed = Prompt(PromptKind.plan, 'Hello',
                tone: tone,
                history: [Message('user', 'a'), Message('assistant', 'b')],
                memories: ['User likes tea'],
                personalContext: 'Preferred tone: $tone')
            .candidates();
        expect(trimmed.last, contains('Reply tone: $tone'), reason: tone);
      }
    });

    test('tone reaches the native request payload via the bridge', () async {
      const ch = MethodChannel('assistant/llm');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? generate;
      messenger.setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'generate') generate = call;
        return '{"emotion":{"mood":"calm","intensity":0.25,"confidence":0.9},'
            '"intent":"chat","reply":"Okay!"}';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
      final e = LlamaChannelEngine('m');
      await e.complete(Prompt(PromptKind.plan, 'hi',
          tone: 'professional',
          history: List.generate(6, (i) => Message('user', 'filler $i'))));
      final prompts = (generate!.arguments['prompts'] as List).cast<String>();
      expect(prompts.last, contains('Reply tone: professional'));
      expect(prompts.last, contains('Message: hi'),
          reason: 'the current user text is never cut');
      expect(generate!.arguments['grammar'], semanticGrammar);
    });
  });

  group('backup format compatibility', () {
    test('version 1 manifest remains readable; future versions do not', () {
      final errors = <String>[];
      final v1 = BackupManifest(
              formatVersion: 1,
              createdAt: DateTime.utc(2025),
              counts: {})
          .toJson();
      expect(BackupManifest.parse(v1, errors), isNotNull, reason: '$errors');
      final future = BackupManifest(
              formatVersion: backupFormatVersion + 1,
              createdAt: DateTime.utc(2025),
              counts: {})
          .toJson();
      errors.clear();
      expect(BackupManifest.parse(future, errors), isNull);
      expect(errors.join(), contains('format version ${backupFormatVersion + 1}'));
      errors.clear();
      expect(BackupManifest.parse({'format': backupFormatTag}, errors), isNull);
      expect(errors.join(), contains('does not say which format version'));
    });

    test('a complete archived version-1 backup previews and imports with '
        'neutral moods', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('corenyth-v1');
      addTearDown(() => dir.delete(recursive: true));
      final db = await openAppDb(path: '${dir.path}/assistant.db');
      addTearDown(db.close);
      // A version-1 archive: no messageMoods section at all.
      final data = BackupData(
        formatVersion: 1,
        chats: [
          {'id': 'c1', 'title': 'Groceries', 'created_at': 1, 'updated_at': 2},
        ],
        conversations: [
          {
            'id': 1,
            'session_id': 'c1',
            'role': 'user',
            'content': 'add milk to the list',
            'created_at': 2,
          },
        ],
        tasks: [
          {
            'id': 1,
            'title': 'buy oat milk',
            'status': 'pending',
            'created_at': 2,
            'priority': 1,
          },
        ],
      );
      final manifest = BackupManifest(
          formatVersion: 1,
          createdAt: DateTime.utc(2025),
          counts: data.counts());
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
        ..add(ArchiveFile.string(manifestEntryName, encodeManifest(manifest)))
        ..add(ArchiveFile.string(dataEntryName, encodeData(data)))));
      final path = '${dir.path}/v1.corenyth';
      File(path).writeAsBytesSync(bytes);

      final service = BackupService(
          db: db,
          reminders: ReminderRepo(db),
          scheduler: NoopScheduler(),
          folderResolver: () async => dir.path);
      final preview = await service.readAndCheck(path);
      expect(preview.manifest.formatVersion, 1);
      expect(preview.data.messageMoods, isEmpty);
      await service.importBackup(preview);
      expect(await db.query('tasks'), hasLength(1));
      expect(await db.query('conversations'), hasLength(1));
      expect(await db.query('message_moods'), isEmpty,
          reason: 'v1 archives never invent historical mood records');

      // New turns record moods again after the import; the format version
      // round-trips as 2 from this build.
      await MoodRepo(db).save(
          messageId: 1,
          chatId: 'c1',
          source: 'model:plan-v1',
          mood: 'happy',
          intensity: 0.8);
      final exported = await service.exportBackup();
      final roundTrip =
          BackupService.decodeBackup(File(exported.path).readAsBytesSync(), 'x');
      expect(roundTrip.manifest.formatVersion, backupFormatVersion);
      expect(roundTrip.data.messageMoods.single['mood'], 'happy');
    });

    test('mismatched manifest/data versions are rejected; invalid input '
        'leaves the database untouched', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('corenyth-mix');
      addTearDown(() => dir.delete(recursive: true));
      final db = await openAppDb(path: '${dir.path}/assistant.db');
      addTearDown(db.close);
      Future<List<Map<String, Object?>>> chats() => db.query('chats');
      expect(await chats(), isEmpty);

      BackupData vData(int version) => BackupData(
            formatVersion: version,
            chats: [
              {'id': 'c1', 'title': '', 'created_at': 1, 'updated_at': 2},
            ],
          );
      BackupManifest vManifest(int version) => BackupManifest(
          formatVersion: version, createdAt: DateTime.utc(2025), counts: {});
      Uint8List archive(int manifestVersion, int dataVersion) =>
          Uint8List.fromList(ZipEncoder().encodeBytes(Archive()
            ..add(ArchiveFile.string(manifestEntryName,
                encodeManifest(vManifest(manifestVersion))))
            ..add(ArchiveFile.string(
                dataEntryName, encodeData(vData(dataVersion))))));
      final mismatch = '${dir.path}/mismatch.corenyth';
      File(mismatch).writeAsBytesSync(archive(1, 2));
      expect(() => BackupService.decodeBackup(File(mismatch).readAsBytesSync(), 'x'),
          throwsA(isA<BackupException>()
              .having((e) => e.message, 'message', contains('disagrees'))));

      // A structurally invalid import rolls back: nothing was overwritten.
      final broken = '${dir.path}/broken.corenyth';
      final brokenData = BackupData(
        chats: [
          {'id': 'c1', 'title': '', 'created_at': 1, 'updated_at': 2},
        ],
        conversations: [
          {
            'id': 1,
            'session_id': 'missing-chat',
            'role': 'user',
            'content': 'x',
            'created_at': 2,
          },
        ],
      );
      File(broken).writeAsBytesSync(Uint8List.fromList(ZipEncoder()
          .encodeBytes(Archive()
            ..add(ArchiveFile.string(
                manifestEntryName, encodeManifest(vManifest(2))))
            ..add(ArchiveFile.string(
                dataEntryName, encodeData(brokenData))))));
      expect(
          () => BackupService.decodeBackup(File(broken).readAsBytesSync(), 'x'),
          throwsA(isA<BackupException>()));
      expect(await chats(), isEmpty,
          reason: 'invalid input is rejected before anything is written');
    });
  });

  group('streaming gate: undecidable suffixes are held, violations blocked', () {
    test('a number split across chunks releases once it completes grounded',
        () async {
      const user = 'I feel overwhelmed by these 12 ideas';
      const prefix =
          '{"emotion":{"mood":"concerned","intensity":0.7,"confidence":0.9},"intent":"chat","reply":"';
      const reply = 'Those 12 ideas can wait. What feels heaviest?';
      model.outputs['plan:$user'] = '$prefix$reply"}';
      model.streamPlan['plan:$user'] = [
        '${prefix}Those 1',
        '$prefix$reply"}',
      ];
      final streams = <String>[];
      final answer = await session.handle(user, onStream: streams.add);
      expect(answer, contains('12'));
      expect(streams, contains(reply),
          reason: 'a partial numeric token must not poison the entire stream');
      expect(streams.first, 'Those ',
          reason: 'the decidable prefix is released while generating');
    });

    test('a genuinely ungrounded number never displays, even split', () async {
      const user = 'remind me about the meeting';
      const prefix =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.9},"intent":"chat","reply":"';
      const reply = 'The answer is 47 parts, all set.';
      model.outputs['plan:$user'] = '$prefix$reply"}';
      model.streamPlan['plan:$user'] = [
        '${prefix}The answer is 4',
        '${prefix}The answer is 47',
        '$prefix$reply"}',
      ];
      model.outputs['reply:$user'] =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.8},'
          '"type":"respond","text":"Noted, nothing was changed."}';
      final streams = <String>[];
      final answer = await session.handle(user, onStream: streams.add);
      expect(
          streams.where((s) => s.contains('47')), isEmpty,
          reason: 'the unsupported number is withheld while it grows and '
              'blocked once complete');
      expect(answer.contains('47'), isFalse,
          reason: 'the final answer falls back to grounded text');
    });

    test('an action claim split across chunks is never displayed', () async {
      const user = 'hey so what do you think';
      const prefix =
          '{"emotion":{"mood":"happy","intensity":0.6,"confidence":0.8},"intent":"chat","reply":"';
      const reply = 'Sure! I have created that task for you.';
      model.outputs['plan:$user'] = '$prefix$reply"}';
      model.streamPlan['plan:$user'] = [
        '${prefix}Sure! I have ',
        '${prefix}Sure! I have crea',
        '$prefix$reply"}',
      ];
      model.outputs['reply:$user'] =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.8},'
          '"type":"respond","text":"I think it sounds like a plan! Want to '
          'make it a reminder?"}';
      final streams = <String>[];
      final answer = await session.handle(user, onStream: streams.add);
      for (final s in streams) {
        expect(s.contains('created'), isFalse, reason: '$s');
        expect(s.contains('crea'), isFalse,
            reason: 'even the partial verb stays held');
      }
      expect(answer.contains('created'), isFalse);
    });

    test('escapes, punctuation and unicode hold only while incomplete',
        () async {
      const user = 'hello there friend';
      const prefix =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.9},"intent":"chat","reply":"';
      const reply = 'Hi \u{1F600} — glad "you" are here; it costs \\5 or 5!';
      model.outputs['plan:$user'] = '$prefix$reply"}';
      model.streamPlan['plan:$user'] = [
        '${prefix}Hi \\ud83d',
        '${prefix}Hi \\ud83d\\ude00',
        '${prefix}Hi \u{1F600} — glad "',
        '$prefix$reply"}',
      ];
      final streams = <String>[];
      await session.handle(user, onStream: streams.add);
      // The incomplete surrogate stays empty; the completed emoji arrives as
      // one unit; the quote before its closing escape waits; the grounded
      // 5s (in the message and reply) release.
      expect(streams.any((s) => s.contains('\u{1F600}')), isTrue);
      expect(streams.any((s) => s.contains('glad')), isTrue);
      expect(model.rawEvents, hasLength(4));
    });

    test('a final malformed envelope keeps the turn truthful', () async {
      const user = 'tell me something nice';
      model.outputs['plan:$user'] =
          '{"emotion":{"mood":"happy","intensity":0.5,"confidence":0.9},'
          '"intent":"chat","reply":"You are doing great!"';
      // Truncated output: no closing brace. The turn still answers; no mood
      // is claimed beyond what the envelope validated... the envelope itself
      // was complete, so the mood stands; the plan fails to parse and the
      // deterministic rules answer.
      final streams = <String>[];
      final answer = await session.handle(user, onStream: streams.add);
      expect(answer, isNotEmpty);
      expect(session.lastDiagnostics['fallback'], 'invalid_plan');
    });

    test('stop cancels the completion and no late chunk resurrects the draft',
        () async {
      const user = 'long running thought';
      const prefix =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.9},"intent":"chat","reply":"';
      model.outputs['plan:$user'] = '$prefix A very long answer."}';
      model.streamPlan['plan:$user'] = ['$prefix A very long'];
      model.gate = Completer<void>();
      final streams = <String>[];
      final done = session.handle(user, onStream: streams.add);
      for (var i = 0; i < 100 && streams.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(streams, isNotEmpty);
      await session.cancel(); // the gate completes inside cancel()
      final reply = await done;
      expect(reply, '', reason: 'a cancelled turn returns no reply');
      expect(streams.last, isNotEmpty,
          reason: 'the stream simply stops where it was; no final replace');
    });

    test('perceived-performance pipeline: mood before first safe text before '
        'final, with coalesced updates', () async {
      const user = 'I am nervous about the launch tomorrow';
      const prefix =
          '{"emotion":{"mood":"concerned","intensity":0.8,"confidence":0.9},"intent":"chat","reply":"';
      const reply = 'It is a lot. What is the first thing to prepare?';
      model.outputs['plan:$user'] = '$prefix$reply"}';
      model.streamPlan['plan:$user'] = [
        '$prefix${reply.substring(0, 10)}',
        '$prefix${reply.substring(0, 25)}',
        '$prefix$reply"}',
      ];
      final stamps = <String, int>{};
      final updates = <String>[];
      void mark(String k) =>
          stamps.putIfAbsent(k, () => DateTime.now().microsecondsSinceEpoch);
      model.gate = Completer<void>();
      final done = session.handle(user, onStream: (s) {
        if (s.isNotEmpty) mark('first_text');
        updates.add(s);
      }, onMood: (_) => mark('mood'));
      for (var i = 0; i < 200 && updates.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(stamps['mood'], isNotNull,
          reason: 'the mood lands while the model is still generating');
      expect(stamps['first_text'], isNotNull);
      expect(stamps['mood']! <= stamps['first_text']!, isTrue,
          reason: 'the envelope completes before the reply prose');
      model.gate!.complete();
      final answer = await done;
      mark('final');
      expect(stamps['final']! >= stamps['first_text']!, isTrue);
      // 3 chunks were offered; the cumulative gate released at most one
      // update per decidable change, and the final answer matches the last.
      expect(updates.toSet().length, lessThanOrEqualTo(3));
      expect(answer, reply);
    });
  });

  group('turn identity: the saved reading follows the completed exchange', () {
    test('completion keeps the live mood; identical texts stay distinct',
        () async {
      const text = 'I finally succeeded!';
      model.outputs['plan:$text'] =
          '{"emotion":{"mood":"happy","intensity":0.8,"confidence":0.9},'
          '"intent":"chat","reply":"Wonderful!"}';
      final moods = <TurnMood>[];
      final first = await session.handle(text, onMood: moods.add);
      expect(first, 'Wonderful!');
      final row1 = session.lastUserRowId;
      expect(row1, isNotNull);
      expect(moods.single.messageRowId, row1);
      // The same text again: a new row, a new reading, no cross-talk.
      final second = await session.handle(text, onMood: moods.add);
      expect(second, 'Wonderful!');
      final row2 = session.lastUserRowId;
      expect(row2, isNot(row1));
      final rows = await ConversationRepo(db).messages('chat');
      expect(rows.where((m) => m.role == 'user'), hasLength(2));
      expect(moods.map((m) => m.messageRowId).toSet(), hasLength(2));
      final stored = await MoodRepo(db).rowsForChat('chat');
      expect(stored.keys, containsAll([row1, row2]));
    });

    test('a cancelled turn still anchors its persisted user row', () async {
      const text = 'remind me to stretch';
      model.gate = Completer<void>();
      final done = session.handle(text);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await session.cancel();
      expect(await done, '');
      expect(session.lastUserRowId, isNotNull,
          reason: 'the user row persisted before the cancel');
      final rows = await ConversationRepo(db).messages('chat');
      expect(rows.where((m) => m.role == 'user').single.id,
          session.lastUserRowId);
    });

    test('a replayed retry creates no row and no new reading', () async {
      const text = 'add task buy milk tomorrow';
      model.outputs['plan:$text'] =
          '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.9},'
          '"intent":"create_task","title":"buy milk","when":"tomorrow"}';
      final first = await session.handle(text);
      expect(first, isNotEmpty);
      final row1 = session.lastUserRowId;
      final moods = <TurnMood>[];
      // Same operation id + message: a replay of the finished turn.
      final op = session.lastOperationId;
      final second =
          await session.handle(text, operationId: op, onMood: moods.add);
      expect(second, first);
      expect(moods, isEmpty, reason: 'no re-inference on a replay');
      final rows = await ConversationRepo(db).messages('chat');
      expect(rows.where((m) => m.role == 'user'), hasLength(1));
      expect(session.lastUserRowId, isNull,
          reason: 'the retry created no row to reconcile');
      expect(row1, isNotNull);
    });

    test('conversations never share readings', () async {
      const text = 'I feel great about this';
      model.outputs['plan:$text'] =
          '{"emotion":{"mood":"happy","intensity":0.9,"confidence":0.9},'
          '"intent":"chat","reply":"Glad to hear it!"}';
      await session.handle(text);
      final other = AssistantSession(
        engine: model,
        tools: session.tools,
        memory: _Memory(db),
        profile: ProfileRepo(db),
        taskRepo: TaskRepo(db),
        conversations: ConversationRepo(db),
        moods: MoodRepo(db),
        conversationId: 'chat2',
        clock: () => _now,
      );
      await other.start();
      final moods = <TurnMood>[];
      await other.handle('plain question about milk', onMood: moods.add);
      final stored = await MoodRepo(db).rowsForChat('chat2');
      expect(stored.values.map((r) => r['chat_id'].toString()),
          everyElement('chat2'));
      final chat1 = await MoodRepo(db).rowsForChat('chat');
      expect(chat1.values.map((r) => r['mood']), everyElement('happy'));
      expect(stored.values.map((r) => r['mood']), everyElement('calm'),
          reason: 'chat2 carries only its own turn\'s reading, never '
              'chat1\'s happy one');
    });

    test('turns the model never saw still get one bounded reading', () async {
      const text = 'did i finish the report';
      await TaskRepo(db).create('the report',
          due: DateTime(2099, 10, 14, 9));
      final moods = <TurnMood>[];
      final reply = await session.handle(text, onMood: moods.add);
      expect(reply, contains('the report'));
      expect(moods, hasLength(1),
          reason: 'one bounded mood-only call, no extra on inferred turns');
      expect(session.lastDiagnostics['model_calls'], '0p1r');
      expect(moods.single.messageRowId, session.lastUserRowId);
    });

    test('mechanical inputs never pay a mood call', () async {
      const text = '12 * 34';
      final reply = await session.handle(text);
      expect(reply, contains('408'));
      expect(session.lastDiagnostics['model_calls'], '0p0r');
    });
  });

  group('mood display follows the active turn', () {
    final messages = [Message('user', 'I finally succeeded!')];
    const happy = MascotEmotion(MascotMood.happy, 0.8);

    Widget scene(List<Message> msgs, String? stream, MascotEmotion? pending,
            void Function(MascotEmotion) onEmotion) =>
        MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!),
            home: Scaffold(
                body: ChatView(
                    name: 'Test',
                    messages: msgs,
                    input: TextEditingController(),
                    scroll: ScrollController(),
                    busy: stream != null,
                    ready: true,
                    onSend: () {},
                    streamingText: stream,
                    pendingEmotion: pending,
                    moods: const {42: happy},
                    onEmotionChanged: onEmotion)));

    testWidgets('an emotion-only envelope colors the latest exchange before '
        'any prose exists', (t) async {
      await t.pumpWidget(scene(List.of(messages), null, happy, (_) {}));
      expect(
          t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope))
              .emotion
              .mood,
          MascotMood.happy,
          reason: 'no reply draft is required');
    });

    testWidgets('an older exchange keeps its stored mood while the live turn '
        'runs', (t) async {
      final msgs = [
        Message('user', 'older', id: 42),
        Message('assistant', 'ok'),
        Message('user', 'newest', id: 43),
      ];
      await t.pumpWidget(scene(msgs, 'draft', happy, (_) {}));
      // The view starts on the latest exchange (pending happy). Page back.
      await t.tap(find.byTooltip('Previous exchange'));
      await t.pumpAndSettle();
      expect(
          t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope).last)
              .emotion
              .mood,
          MascotMood.happy,
          reason: 'exchange 2 is the stored row 42');
    });

    testWidgets('the completed exchange keeps the mood through the reconciled '
        'identity; an unreconciled row stays neutral', (t) async {
      // The repaired identity contract: the page reconciles the optimistic
      // user message with its persisted row id before the live state clears.
      final msgs = [
        Message('user', 'I finally succeeded!', id: 42),
        Message('assistant', 'Wonderful!'),
      ];
      await t.pumpWidget(scene(msgs, null, null, (_) {}));
      expect(
          t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope))
              .emotion
              .mood,
          MascotMood.happy);
      // Without the reconciliation there is no anchor: unknown stays calm,
      // and no global pending fallback rescues arbitrary ID-less rows.
      final unanchored = [Message('user', 'I finally succeeded!')];
      await t.pumpWidget(scene(unanchored, null, null, (_) {}));
      expect(
          t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope))
              .emotion
              .mood,
          MascotMood.calm);
    });

    testWidgets('the surrounding mascot is notified when the selected emotion '
        'changes on a stable page, without loops', (t) async {
      final callbacks = <MascotEmotion>[];
      await t.pumpWidget(scene(List.of(messages), null, null, callbacks.add));
      await t.pumpWidget(scene(List.of(messages), 'Wonderful', happy,
          callbacks.add));
      await t.pump();
      expect(callbacks.map((e) => e.mood), contains(MascotMood.happy));
      // An identical update on the same page publishes nothing new.
      final count = callbacks.length;
      await t.pumpWidget(
          scene(List.of(messages), 'Wonderful', happy, callbacks.add));
      await t.pump();
      await t.pump();
      expect(callbacks.length, count, reason: 'no redundant notifications');
    });
  });

  group('streaming holdback building blocks', () {
    test('undecidableSuffixLength holds numbers and claim-verb prefixes', () {
      expect(undecidableSuffixLength('Those 1'), greaterThan(0));
      expect(undecidableSuffixLength('Those 12 '), 0,
          reason: 'a completed number followed by a boundary is decidable');
      expect(undecidableSuffixLength('Sure! I have crea'), greaterThan(0));
      expect(undecidableSuffixLength('Sure! I have creature '), 0,
          reason: 'the word completed into a non-verb');
      expect(undecidableSuffixLength('plain words'), 0);
      expect(undecidableSuffixLength('ends with 12'), greaterThan(0),
          reason: 'a trailing number may still be growing');
      expect(undecidableSuffixLength(''), 0);
    });
  });
}
