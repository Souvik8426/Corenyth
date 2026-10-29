import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/mascot/mood_store.dart';
import 'package:flutter_test/flutter_test.dart';

TurnMood mood(MascotMood m,
        {String turn = 'op1',
        String chat = 'c1',
        int? row,
        String source = 'model:plan-v1'}) =>
    TurnMood(
        source: source,
        conversationId: chat,
        turnId: turn,
        generationId: '$turn/g',
        emotion: MascotEmotion(m, 0.7),
        messageRowId: row);

void main() {
  test('a new turn resets the display to unknown, first valid event wins', () {
    final store = MoodController(conversationId: 'c1');
    store.beginTurn('op1');
    expect(store.pending.known, isFalse);
    expect(store.accept(mood(MascotMood.concerned)), isTrue);
    expect(store.pending.emotion!.mood, MascotMood.concerned);
    // A second reading of the same turn (e.g. the reply call's envelope)
    // changes nothing: the turn transitions once.
    expect(store.accept(mood(MascotMood.happy)), isFalse);
    expect(store.pending.emotion!.mood, MascotMood.concerned);
  });

  test('events after endTurn, stop, or a newer turn are stale', () {
    final store = MoodController(conversationId: 'c1');
    store.beginTurn('op1');
    store.endTurn();
    expect(store.accept(mood(MascotMood.happy)), isFalse,
        reason: 'the window closed with the turn');
    store.cancelPending();
    expect(store.accept(mood(MascotMood.happy)), isFalse);

    store.beginTurn('op2');
    store.beginTurn('op3'); // a newer request supersedes op2
    expect(store.accept(mood(MascotMood.happy, turn: 'op2')), isFalse,
        reason: 'stale turn id');
    expect(store.accept(mood(MascotMood.happy, turn: 'op3')), isTrue);
  });

  test('no chat inherits another chat\'s emotion; rows anchor history', () {
    final store = MoodController(conversationId: 'c1');
    store.beginTurn('op1');
    store.accept(mood(MascotMood.excited, chat: 'c2'),
        ); // cross-conversation: dropped
    expect(store.pending.known, isFalse);
    store.accept(mood(MascotMood.excited, row: 41));
    expect(store.moodFor(41).emotion!.mood, MascotMood.excited);
    expect(store.moodFor(99).known, isFalse,
        reason: 'rows without a record display unknown/calm');
    expect(store.moodFor(null).known, isFalse);
  });

  test('history survives via the constructor; cancelPending clears pending',
      () {
    final store = MoodController(conversationId: 'c1', history: {
      7: mood(MascotMood.happy, turn: 'op0', row: 7),
    });
    expect(store.moodFor(7).emotion!.mood, MascotMood.happy);
    store.beginTurn('op1');
    store.accept(mood(MascotMood.concerned, row: 8));
    store.cancelPending(); // stop: the display resets...
    expect(store.pending.known, isFalse);
    expect(store.moodFor(8).known, isTrue,
        reason: '...but an accepted record stays with its exchange');
    expect(store.moodFor(7).emotion!.mood, MascotMood.happy);
    store.dispose();
    expect(store.moodFor(7).known, isFalse);
    expect(store.accept(mood(MascotMood.happy)), isFalse);
  });
}
