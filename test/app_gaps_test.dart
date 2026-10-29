import 'package:assistant/assistant/calculator.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:flutter_test/flutter_test.dart';

// Phrasings the held-out run showed the app's own rules missing; each test
// pins the rule, not the eval case.
void main() {
  final now = DateTime(2026, 10, 19, 7, 41);
  final rules = RuleEngine(clock: () => now);

  group('daily repeats by part of day', () {
    test('every evening at 9 until a date', () {
      final d = rules.parseDaily(
          'every evening at 9 remind me to journal until 30 November')!;
      expect(d.problem, isNull);
      expect((d.schedule!.hour, d.schedule!.minute), (21, 0));
      expect(d.schedule!.until, DateTime(2026, 11, 30, 21, 0));
      expect(d.schedule!.rest, isNot(contains('evening')));
    });

    test('each night with an explicit pm time', () {
      final d = rules.parseDaily(
          'each night at 10:30 pm remind me to take my vitamins')!;
      expect((d.schedule!.hour, d.schedule!.minute), (22, 30));
      expect(d.schedule!.until, isNull);
      expect(d.schedule!.rest, isNot(contains('night')));
    });

    test('every morning keeps the morning reading of the clock', () {
      final d = rules.parseDaily('remind me every morning at 6:45 to stretch')!;
      expect((d.schedule!.hour, d.schedule!.minute), (6, 45));
      expect(d.schedule!.rest, isNot(contains('morning')));
    });

    test('a one-off morning is not a repeat', () {
      expect(rules.parseDaily('remind me tomorrow morning at 7 to run'), isNull);
    });
  });

  group('explicit memory cues', () {
    test('cue words other than "remember"', () {
      for (final t in [
        "fyi my brother's name is Kabir",
        "don't forget that I'm vegetarian",
        'keep in mind I work night shifts',
        'note that my landlord is Mr Rao',
        'my gym is Cult Fit, keep that in mind',
      ]) {
        expect(RuleEngine.isExplicitRemember(t), isTrue, reason: t);
        expect(rules.extractMemory(t)['remember'], isTrue, reason: t);
      }
      expect(rules.extractMemory("fyi my brother's name is Kabir")['memory'],
          "User's brother's name is Kabir");
      expect(rules.extractMemory("don't forget that I'm vegetarian")['memory'],
          'User is vegetarian');
    });

    test('tasks and reminders are not memories', () {
      for (final t in [
        'remember to buy milk',
        "don't forget to call mom at 5",
        'note to self: pay rent tomorrow',
      ]) {
        expect(rules.extractMemory(t)['remember'], isNot(true), reason: t);
      }
    });

    test('a correction states the new value and what it replaces', () {
      const moved = "I no longer live in Pune, I'm in Bangalore now";
      expect(RuleEngine.isExplicitRemember(moved), isTrue);
      expect(rules.extractMemory(moved)['memory'], 'User lives in Bangalore');
      expect(RuleEngine.correctedObject(moved), 'in Pune');

      const drink = "I don't drink soda anymore, switched to juice";
      expect(rules.extractMemory(drink)['memory'], 'User drinks juice');
      expect(RuleEngine.correctedObject(drink), 'soda');
    });

    test('a plain refusal is not a correction', () {
      expect(RuleEngine.correctedObject("I don't want to go, it's raining"),
          isNull);
      expect(RuleEngine.isExplicitRemember("I don't want to go, it's raining"),
          isFalse);
    });
  });

  group('"not X, but <request>"', () {
    test('keeps the request after "but"', () {
      expect(
          RuleEngine.contrastRequest(
              'not tonight, but remind me tomorrow at 8am to pay rent'),
          'remind me tomorrow at 8am to pay rent');
    });

    test('a refusal stays a refusal', () {
      expect(RuleEngine.contrastRequest("not now, but don't remind me later"),
          isNull);
      expect(RuleEngine.contrastRequest('not today, but thanks'), isNull);
      expect(RuleEngine.contrastRequest("don't remind me to call Bob"), isNull);
    });
  });

  group('percent arithmetic', () {
    test('percent of a number', () {
      expect(calculate('what is 20 percent of 350'), '20% of 350 = 70.');
      expect(calculate('how much is 12.5% of 80'), '12.5% of 80 = 10.');
      expect(calculate('7% of 50?'), '7% of 50 = 3.5.');
    });

    test('plain arithmetic is unchanged', () {
      expect(calculate('what is 2 + 3'), '2 + 3 = 5.');
      expect(calculate('20 percent of my time'), isNull);
    });
  });
}
