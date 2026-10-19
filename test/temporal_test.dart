import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/temporal.dart';
import 'package:flutter_test/flutter_test.dart';

/// P1: the shared resolver, read against one captured submission instant
/// (plan §6 fixed time: Mon 19 Oct 2026, 07:41 local).
void main() {
  final now = DateTime(2026, 10, 19, 7, 41);
  DateTime t(int h, int m, [int day = 19]) => DateTime(2026, 10, day, h, m);
  TemporalReading read(String s) => Temporal.read(s, now);

  test('duration forms, short units, word numbers and word order agree', () {
    for (final (say, want) in [
      ('call Mum in 10 mins', t(7, 51)),
      ('call Mum in 10 minutes', t(7, 51)),
      ('call Mum in 10min', t(7, 51)),
      ('call Mum in 10m', t(7, 51)),
      ('call Mum in ten minutes', t(7, 51)),
      ('call Mum after 10 min', t(7, 51)),
      ('after 10 min call Mum', t(7, 51)),
      ('call Mum 10 minutes from now', t(7, 51)),
      ('call Mum 10 mins later', t(7, 51)),
      ("call Mum in 10 minutes' time", t(7, 51)),
      ('call Mum in about 10 minutes', t(7, 51)),
      ('call Mum in twenty-five minutes', t(8, 6)),
      ('call Mum in twenty five minutes', t(8, 6)),
      ('call Mum in a couple of minutes', t(7, 43)),
      ('call Mum in 2 hrs', t(9, 41)),
      ('call Mum in 2h', t(9, 41)),
      ('call Mum in an hour', t(8, 41)),
      ('call Mum in half an hour', t(8, 11)),
      ('call Mum half an hour from now', t(8, 11)),
      ('call Mum in an hour and a half', t(9, 11)),
      ('call Mum in one and a half hours', t(9, 11)),
      ('call Mum in 1.5 hours', t(9, 11)),
      ('call Mum in 1h30', t(9, 11)),
      ('call Mum in 1 hour 30 minutes', t(9, 11)),
      ('call Mum in 1 hour and 30 minutes', t(9, 11)),
      ('call Mum in a quarter of an hour', t(7, 56)),
      ('call Mum in 61 minutes', t(8, 42)),
      ('call Mum in 24 hours', t(7, 41, 20)),
      ('call Mum in 2 days', t(7, 41, 21)),
    ]) {
      final r = read(say);
      expect(r.status, TemporalStatus.resolved, reason: say);
      expect(r.at, want, reason: say);
      expect(r.rest, 'call Mum', reason: say);
    }
  });

  test('calendar forms and disclosed defaults are unchanged', () {
    for (final (say, want, note) in [
      ('call Mum tomorrow at 8am', t(8, 0, 20), null),
      ('call Mum at 6:30 pm', t(18, 30), null),
      ('call Mum tonight', t(20, 0), 'Tonight means 8 PM unless you say otherwise.'),
      ('call Mum on 5 November', DateTime(2026, 11, 5, 9), "I used 9 AM since you didn't give a time."),
      ('call Mum friday at 11', t(11, 0, 23), null),
      ('call Mum tomo', t(9, 0, 20), "I used 9 AM since you didn't give a time."),
      ('call Mum at 7', t(19, 0), 'I took that as 7 PM.'),
    ]) {
      final r = read(say);
      expect(r.at, want, reason: say);
      expect(r.note, note, reason: say);
      expect(r.rest, 'call Mum', reason: say);
    }
  });

  test('"within" is the event being that close, unless it is a deadline', () {
    final event = read('i have a meeting within 10 mins');
    expect(event.at, t(7, 51));
    expect(event.role, TemporalRole.eventStart);
    expect(event.anchor!.relation, TemporalRelation.within);
    expect(event.rest, 'i have a meeting');
    expect(event.note, 'I read "within 10 mins" as 10 minutes from now.');

    for (final say in [
      'Finish this within 10 minutes',
      'submit the report within 2 hours',
      'sometime within the next hour I need to call the courier',
    ]) {
      final r = read(say);
      expect(r.role, TemporalRole.deadline, reason: say);
      expect(r.note, isNull, reason: say);
    }
    expect(read('sometime within the next hour I need to call the courier').rest,
        'I need to call the courier');
    expect(read('submit the report within 2 hours').at, t(9, 41));

    final before = read('submit the report before 5pm');
    expect(before.role, TemporalRole.deadline);
    expect(before.anchor!.relation, TemporalRelation.before);
    expect(before.at, t(17, 0));
    expect(before.rest, 'submit the report');
  });

  test('lead time, event length and recurrence keep their own roles', () {
    final lead = read('Meeting in 10 minutes, remind me 5 minutes before');
    expect(lead.at, t(7, 51));
    expect(lead.lead, const Duration(minutes: 5));
    expect(lead.role, TemporalRole.eventStart);
    expect(lead.rest, 'Meeting , remind me');

    final long = read('meeting in 10 minutes for half an hour');
    expect(long.at, t(7, 51));
    expect(long.end, t(8, 21));
    expect(long.rest, 'meeting');

    // A length alone is not a start, and stays in the text.
    final alone = read('meeting for 30 minutes');
    expect(alone.status, TemporalStatus.none);
    expect(alone.end, isNull);

    final every = read('drink water every 2 hours');
    expect(every.status, TemporalStatus.unsupported);
    expect(every.at, isNull);
    expect(every.spans.single.role, TemporalRole.recurrence);
  });

  test('conflicting times are reported, never first-match', () {
    for (final say in [
      'Meeting in 10 minutes at 9',
      'meeting at 9 in 10 minutes',
      'call Mum in 10 minutes in 20 minutes',
      'call Mum tomorrow in an hour',
      'call Mum morning 8pm',
      'call Mum at 8:10 then 9pm',
    ]) {
      final r = read(say);
      expect(r.status, TemporalStatus.conflict, reason: say);
      expect(r.at, isNull, reason: say);
    }
    expect(read('Meeting in 10 minutes at 9').conflictText,
        '"in 10 minutes" and "at 9"');
    // A day offset with a clock time is one time, not two.
    expect(read('call Mum in 2 days at 5pm').at, t(17, 0, 21));
    // Two amounts with a comma: an alert offset and a lead, not 15 minutes.
    expect(read('call Mum in 10 minutes, 5 minutes before').at, t(7, 51));
  });

  test('whole-message problems outrank any valid part', () {
    // Two same-rank amounts: both are read, so they disagree.
    for (final say in [
      'remind me in 1 hour and 2 hours to call Mum',
      'remind me in 10 minutes and 20 minutes to call Mum',
      'call Mum 1 hour and 2 hours from now',
    ]) {
      final r = read(say);
      expect(r.status, TemporalStatus.conflict, reason: say);
      expect(r.spans.where((s) => s.amount != null), hasLength(2),
          reason: say);
    }
    // Two named days that disagree: a conflict naming both.
    final days = read('remind me tomorrow Friday at 5pm to call Mum');
    expect(days.status, TemporalStatus.conflict);
    expect(days.conflictText, contains('tomorrow'));
    expect(days.conflictText, contains('Friday'));
    // Units, repeats and impossible dates/times the app doesn't schedule.
    for (final say in [
      'remind me in 2 weeks at 5pm to call Mum',
      'remind me in a week to call Mum',
      'remind me in 30 seconds to call Mum',
      'call Mum 3 months from now at 5pm',
      'remind me every 2 hours at 5pm to drink water',
      'remind me every week at 5pm to call Mum',
      'remind me weekly at 5pm to call Mum',
      'remind me every Monday at 5pm to call Mum',
      'remind me in 10 minutes on 30 February to call Mum',
      'remind me in 10 minutes at 13pm to call Mum',
    ]) {
      final r = read(say);
      expect(r.status, TemporalStatus.unsupported, reason: say);
      expect(r.at, isNull, reason: say);
    }
    // Lead phrases of any duration form come from the same reading.
    final half = read('remind me about the meeting in 2 hours half an hour before');
    expect(half.at, t(9, 41));
    expect(half.lead, const Duration(minutes: 30));
    // Unchanged: a weekday that agrees with the date, and "every day" (daily).
    expect(read('call Mum on Monday 19 October at 5pm').at, t(17, 0));
    expect(read('remind me to call Mum in second place').status,
        TemporalStatus.none);
  });

  test('non-durations stay text', () {
    for (final say in [
      'call Mum in the evening',
      'room 10 meeting',
      '10 minutes call Mum',
      'call Mum in a few minutes',
      'read 10 min article',
    ]) {
      final r = read(say);
      expect(r.spans.where((s) => s.amount != null && s.relation != TemporalRelation.lasting),
          isEmpty,
          reason: say);
    }
    expect(read('call Mum in the evening').at, t(19, 0));
    expect(read('read 10 min article').status, TemporalStatus.none);
  });

  test('parseDuration keeps postpone/lead amounts and adds natural forms', () {
    for (final (say, mins) in [
      ('by 2h', 120),
      ('for 30 minutes', 30),
      ('2 hours', 120),
      ('a day', 1440),
      ('30m', 30),
      ('ten mins', 10),
      ('an hour and a half', 90),
      ('half an hour', 30),
    ]) {
      expect(RuleEngine.parseDuration(say), Duration(minutes: mins), reason: say);
    }
    for (final say in ['soon', '10', 'in 10 minutes', '10 minutes and 5 minutes']) {
      expect(RuleEngine.parseDuration(say), isNull, reason: say);
    }
  });

  test('the rules route the screenshot and word-order variants identically', () {
    final r = RuleEngine(clock: () => now);
    for (final (say, title) in [
      ('Can u remind me i have a meeting within 10 mins', 'meeting'),
      ('Remind me in ten minutes to call Mum', 'call Mum'),
      ('after 10 min remind me to call Mum', 'call Mum'),
      ('remind me to call Mum after 10 min', 'call Mum'),
      ('remind me to call Mum 10 mins from now', 'call Mum'),
      ('in 10 mins remind me to call Mum', 'call Mum'),
    ]) {
      final call = r.fastRoute(say);
      expect(call?['tool'], 'create_reminder', reason: say);
      final args = call!['arguments'] as Map;
      expect(args['title'], title, reason: say);
      expect(args['at'], '2026-10-19T07:51:00.000', reason: say);
    }
    expect(r.fastRoute('in 45 minutes remind me the laundry is done')!['arguments'],
        {'title': 'the laundry is done', 'at': '2026-10-19T08:26:00.000'});
    expect(r.fastRoute('Doctor appointment on friday at 11, remind me')!['arguments'],
        {'title': 'Doctor appointment', 'at': '2026-10-23T11:00:00.000'});
    expect(r.fastRoute('remind me in an hour and a half to move the car')!['arguments'],
        containsPair('at', '2026-10-19T09:11:00.000'));
    expect(
        r.fastRoute('set an alarm for half an hour from now to check the oven')!['arguments'],
        {'title': 'check the oven', 'at': '2026-10-19T08:11:00.000'});
  });
}
