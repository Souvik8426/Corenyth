import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/follow_through.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart'
    show
        FakeTasks,
        FakeReminders,
        FakeMemory,
        FakeProfile,
        FakeConversations,
        SpyEngine;

/// Answers each prompt kind with its own scripted output and keeps the
/// rendered prompts, so a test can see what the model was shown.
class ScriptedEngine extends SpyEngine {
  final outputs = <PromptKind, String>{};
  final prompts = <Prompt>[];
  @override
  Future<String> complete(Prompt p) async {
    calls++;
    prompts.add(p);
    return outputs[p.kind] ?? output;
  }
}

String respond(String text) => jsonEncode({'type': 'respond', 'text': text});

void main() {
  late FakeTasks tasks;
  late FakeConversations conversations;
  late ScriptedEngine model;
  late AssistantSession session;
  setUp(() async {
    tasks = FakeTasks();
    conversations = FakeConversations();
    model = ScriptedEngine();
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, FakeReminders(), FakeMemory(), NoopScheduler()),
      memory: FakeMemory(),
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: conversations,
    );
    await session.start();
    addTearDown(session.close);
  });

  const meeting =
      "I am done with the meeting with ceo, she never replied soo didn't get the chance to have a meet";
  const parroted =
      'I am done with the meeting with ceo, she never replied so I will now move on from this task.';

  test('screenshot 1: the finished meeting closes its task and is not parroted',
      () async {
    final milk = await tasks.create('buy milk');
    final ceo =
        await tasks.create('schedule a meet with ceo of komal goyal studios');
    model.outputs[PromptKind.reply] = respond(parroted);

    final reply = await session.handle(meeting);

    expect((await tasks.get(ceo.id))!.done, isTrue);
    expect((await tasks.get(ceo.id))!.outcome, contains('never replied'));
    expect((await tasks.get(milk.id))!.done, isFalse);
    expect(reply, isNot(contains('I will now move on')));
    expect(echoes(reply, meeting), isFalse);
  });

  test('screenshot 2: complaints re-answer the earlier message, not the rules',
      () async {
    final ceo =
        await tasks.create('schedule a meet with ceo of komal goyal studios');
    model.outputs[PromptKind.reply] = respond(parroted);
    await session.handle(meeting);

    // The model would say "Wow, that was fast." again: a canned plan reply.
    model.outputs[PromptKind.plan] = jsonEncode({
      'intent': 'chat',
      'reply': 'Wow, that was fast. Let me know if there is anything else.'
    });
    final second = await session.handle('Wow u just replied what i prompted');
    expect(second, isNot(contains('that was fast')));
    expect(second, startsWith('Sorry'));
    expect(second, contains('#${ceo.id}'));

    final third = await session.handle(
        "That wasn't fast that was dumb 😭 plz give a proper reply of my previous prompt");
    expect(third, isNot(contains("I'm not sure what you'd like")));
    expect(third, contains('#${ceo.id}'));
    expect(third, contains('marked done'));
    // The re-answer is about the meeting message, never the complaints.
    final reAnswer = model.prompts.last;
    expect(reAnswer.kind, PromptKind.reply);
    expect(reAnswer.user, meeting);
  });

  test('a good model re-answer is used for a complaint', () async {
    await tasks.create('schedule a meet with ceo of komal goyal studios');
    await session.handle(meeting);
    model.outputs[PromptKind.reply] = respond(
        "Sorry about that! Since she never replied, want a reminder to try her again next week?");
    final reply = await session.handle('that was dumb, give a proper reply');
    expect(reply, startsWith('Sorry about that!'));
  });

  test('chat answers from the plan; a parroted plan reply gets a reply call with recent turns',
      () async {
    model.outputs[PromptKind.plan] =
        jsonEncode({'intent': 'chat', 'reply': 'Welcome back! Goa sounds lovely.'});
    model.outputs[PromptKind.reply] = respond('unused');
    expect(await session.handle('hey, just got back from a trip to goa'),
        'Welcome back! Goa sounds lovely.');
    expect(model.prompts.last.kind, PromptKind.plan,
        reason: 'one model call per chat turn');

    model.outputs[PromptKind.plan] =
        jsonEncode({'intent': 'chat', 'reply': 'it was so relaxing honestly'});
    model.outputs[PromptKind.reply] =
        respond('Glad the trip went well! Anything you want to plan next?');
    final reply = await session.handle('it was so relaxing honestly');
    expect(reply, 'Glad the trip went well! Anything you want to plan next?');
    final p = model.prompts.last;
    expect(p.kind, PromptKind.reply);
    expect(p.history.map((m) => m.content),
        contains('hey, just got back from a trip to goa'));
    expect(p.render(), contains('trip to goa'));
  });

  test('chat history leaves out task lists and check-ins', () async {
    model.outputs[PromptKind.plan] = jsonEncode({'intent': 'chat'});
    model.outputs[PromptKind.reply] = respond('Sounds lovely.');
    await conversations.add('x', 'assistant', 'Pending tasks:\n#1 buy milk');
    await session.handle('nice weather here');
    final p = model.prompts.last;
    expect(p.history.any((m) => m.content.contains('#1')), isFalse);
  });

  group('echoes', () {
    test('catches parroting', () {
      expect(echoes(parroted, meeting), isTrue);
      expect(echoes('it was so relaxing honestly', 'it was so relaxing honestly'),
          isTrue);
    });
    test('allows real replies', () {
      expect(echoes('Glad to hear it! Want a reminder?', meeting), isFalse);
      expect(
          echoes('Sorry she never replied. Want a reminder to try again?',
              meeting),
          isFalse);
    });
  });

  group('isComplaint', () {
    test('matches the screenshot messages', () {
      expect(isComplaint('Wow u just replied what i prompted'), isTrue);
      expect(
          isComplaint(
              "That wasn't fast that was dumb 😭 plz give a proper reply of my previous prompt"),
          isTrue);
      expect(isComplaint('answer my previous question'), isTrue);
    });
    test('ignores outcomes and commands', () {
      expect(isComplaint('the meeting went badly, it was bad'), isFalse);
      expect(isComplaint('done with buy milk'), isFalse);
      expect(isComplaint('remind me to call mom tomorrow'), isFalse);
    });
  });
}
