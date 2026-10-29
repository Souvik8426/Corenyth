import 'dart:async';
import 'dart:io';

import 'package:assistant/data/repos.dart';
import 'package:assistant/main.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/model_status.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/ui/mascot_emotion_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

/// Turn-identity coverage through the real page boundary: AssistantSession +
/// ChatPage + AppServices over migrated SQLite, with the native llama bridge
/// mocked (the same channel protocol LlamaBridge implements). No device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const llm = MethodChannel('assistant/llm');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final happyPlan = (String reply) =>
      '{"emotion":{"mood":"happy","intensity":0.8,"confidence":0.9},'
      '"intent":"chat","reply":"$reply"}';

  /// Emits a cumulative native text event like the real bridge.
  Future<void> emit(int id, String text) =>
      messenger.handlePlatformMessage(
          llm.name,
          StandardMethodCodec()
              .encodeMethodCall(MethodCall('text', {'id': id, 'text': text})),
          (_) {});

  /// Generates by streaming canned chunks, optionally holding the completion.
  /// Returns the last prompt's `Message:` line so tests can route by input.
  void installBridge({
    required String Function(String userText) planFor,
    Completer<void>? hold,
    List<String> Function(String userText)? chunksFor,
  }) {
    messenger.setMockMethodCallHandler(llm, (call) async {
      switch (call.method) {
        case 'load':
          return true;
        case 'unload':
          return null;
        case 'cancel':
          hold?.complete();
          return null;
        case 'generate':
          final id = call.arguments['id'] as int;
          final prompts = (call.arguments['prompts'] as List).cast<String>();
          final last = prompts.last;
          final user = last.contains('Message: ')
              ? last.split('Message: ').last.split(' /no_think').first.trim()
              : last;
          final raw = planFor(user);
          for (final chunk in chunksFor?.call(user) ?? [raw]) {
            await emit(id, chunk);
          }
          if (hold != null) await hold.future;
          return raw;
        default:
          return null;
      }
    });
  }

  late AppServices services;
  late File modelFile;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('corenyth-identity');
    modelFile = File('${tempDir.path}/model.gguf');
    // checkModelPath compares the file length against the catalog byte size;
    // a sparse write extends the file without cost on the host filesystem.
    final raf = await modelFile.open(mode: FileMode.write);
    await raf.setPosition(modelBytes - 1);
    await raf.writeByte(0);
    await raf.close();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(llm, null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('streaming and completed views keep one accepted mood, and the '
      'optimistic message reconciles with its persisted row', (t) async {
    await t.runAsync(() async {
      final db = await openMigratedV2();
      services = AppServices(db, NoopScheduler(), modelFile.path);
      addTearDown(db.close);
    });
    const text = 'I finally succeeded!';
    installBridge(planFor: (user) => happyPlan('Wonderful!'));
    await t.pumpWidget(MaterialApp(
        home: ChatPage(services,
            name: 'Ari', onEmotionChanged: (_) {}, onChanged: () {})));
    await settle(t);
    expect(find.text('A little space to think.'), findsNothing);

    await t.enterText(find.byKey(const ValueKey('chat-composer')), text);
    await t.pump();
    await t.tap(find.byTooltip('Send message'));
    // While streaming, the scope shows the model's happy reading.
    await settle(t);
    final scopes = find.byType(MascotEmotionScope);
    expect(t.widget<MascotEmotionScope>(scopes.first).emotion.mood,
        MascotMood.happy,
        reason: 'the live reading shows during the turn');
    expect(find.text('Wonderful!'), findsOneWidget);

    // After the turn settles (pending cleared), the completed exchange keeps
    // the same mood through the reconciled row identity.
    await settle(t);
    expect(
        t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion
            .mood,
        MascotMood.happy,
        reason: 'completion must not fall back to calm');

    // The persisted rows agree: one user row carries the reading.
    final db = services.db;
    final rows = await t.runAsync(
        () => db.query('conversations', where: "role = 'user'")) ?? [];
    expect(rows, hasLength(1));
    final rowId = rows.single['id'] as int;
    final moods = await t.runAsync(() => db.query('message_moods')) ?? [];
    expect(moods.single['message_id'], rowId);
    expect(moods.single['mood'], 'happy');

    // Identical consecutive message: a new row, its own reading, no crosstalk.
    await t.enterText(find.byKey(const ValueKey('chat-composer')), text);
    await t.pump();
    await t.tap(find.byTooltip('Send message'));
    await settle(t);
    final userRows = await t.runAsync(
        () => db.query('conversations', where: "role = 'user'")) ?? [];
    expect(userRows, hasLength(2));
    expect(
        t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion
            .mood,
        MascotMood.happy);
    final allMoods = await t.runAsync(() => db.query('message_moods')) ?? [];
    expect(allMoods.map((r) => r['message_id']),
        userRows.map((r) => r['id']), reason: 'every turn anchors its own row');
  });

  testWidgets('a stopped turn leaves no draft, and late native events cannot '
      'resurrect it', (t) async {
    await t.runAsync(() async {
      final db = await openMigratedV2();
      services = AppServices(db, NoopScheduler(), modelFile.path);
      addTearDown(db.close);
    });
    final hold = Completer<void>();
    installBridge(
        planFor: (user) => happyPlan('A long answer.'),
        hold: hold,
        chunksFor: (user) => [
              '{"emotion":{"mood":"happy","intensity":0.8,"confidence":0.9}',
              '{"emotion":{"mood":"happy","intensity":0.8,"confidence":0.9},'
                  '"intent":"chat","reply":"A long',
            ]);
    await t.pumpWidget(
        MaterialApp(home: ChatPage(services, name: 'Ari')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('chat-composer')), 'hello');
    await t.pump();
    await t.tap(find.byTooltip('Send message'));
    await settle(t);
    expect(find.textContaining('A long'), findsOneWidget,
        reason: 'the streamed draft is visible before completion');
    final moodBeforeStop =
        t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion;

    await t.tap(find.text('Stop'));
    await settle(t);
    expect(find.textContaining('A long'), findsNothing,
        reason: 'the draft is withdrawn, never finalised');
    expect(find.text('Response stopped.'), findsOneWidget);
    // The stopped reply shows nothing, but the reading the model already
    // returned for the persisted user turn stays with that exchange (its row
    // was reconciled before the live state cleared). No new reading is
    // invented and late events are ignored.
    expect(
        t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion,
        moodBeforeStop);

    // A late native event after the cancel reaches no listener: the draft
    // stays gone.
    await messenger.handlePlatformMessage(
        llm.name,
        StandardMethodCodec().encodeMethodCall(
            MethodCall('text', {'id': 999999, 'text': 'late chunk'})),
        (_) {});
    await settle(t);
    expect(find.textContaining('late chunk'), findsNothing);
    expect(find.textContaining('A long'), findsNothing);
    expect(moodBeforeStop.mood, MascotMood.happy);
  });

  testWidgets('another conversation never inherits a reading', (t) async {
    await t.runAsync(() async {
      final db = await openMigratedV2();
      services = AppServices(db, NoopScheduler(), modelFile.path);
      addTearDown(db.close);
      await services.conversations.ensureMainChat();
      // A prior conversation with a stored happy reading.
      await services.conversations.add(
          ConversationRepo.mainChatId, 'user', 'older turn');
      await services.moods.save(
          messageId: (await services.conversations
                  .messages(ConversationRepo.mainChatId))
              .last
              .id!,
          chatId: ConversationRepo.mainChatId,
          source: 'model:plan-v1',
          mood: 'happy',
          intensity: 0.9);
    });
    installBridge(planFor: (user) => happyPlan('Okay!'));
    // Open a NEW conversation: nothing to inherit.
    await t.pumpWidget(MaterialApp(
        home: ChatPage(services,
            name: 'Ari', conversationId: 'brand-new-chat')));
    await settle(t);
    expect(
        t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion
            .mood,
        MascotMood.calm);
  });
}
