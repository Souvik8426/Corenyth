import 'package:assistant/assistant/rule_engine.dart';
import 'package:flutter_test/flutter_test.dart';

// Thursday 15 October 2026, 10:00 local.
final _now = DateTime(2026, 10, 15, 10);

void main() {
  final r = RuleEngine(clock: () => _now);
  Map<String, Object?>? args(String say, [RuleEngine? e]) =>
      (e ?? r).fastRoute(say)?['arguments'] as Map<String, Object?>?;

  /// Nothing is written and nothing guessed: no fast route, no clarify draft.
  void refused(String say, [RuleEngine? e]) {
    final x = e ?? r;
    expect(x.fastRoute(say), isNull, reason: say);
    expect(x.maybeClarify(say), isNull, reason: say);
    expect(x.plan(say)['type'], 'respond', reason: say);
  }

  test('named and ISO dates, with and without a year', () {
    for (final say in [
      'remind me on 5 November at 9am to pay rent',
      'remind me Nov 5th at 9am to pay rent',
      'remind me on the 5th of November at 9am to pay rent',
      'remind me November 5 at 9am to pay rent',
      'remind me on 2026-11-05 at 9am to pay rent',
      '5 November 9am remind me to pay rent',
    ]) {
      expect(args(say), {'title': 'pay rent', 'at': '2026-11-05T09:00:00.000'},
          reason: say);
    }
    expect(args('remind me on 5 November 2027 at 9am to pay rent')!['at'],
        '2027-11-05T09:00:00.000');
    // a day alone takes the disclosed 9 AM default
    final day = r.fastRoute('add task pay rent on 5 November')!;
    expect(day['arguments'],
        {'title': 'pay rent', 'due': '2026-11-05T09:00:00.000'});
    expect(day['note'], contains('9 AM'));
  });

  test('weekdays: the next one, today included; past today asks', () {
    expect(args('remind me on monday at 9am to call Bob')!['at'],
        '2026-10-19T09:00:00.000');
    expect(args('Monday 8am remind me to call Mum')!['at'],
        '2026-10-19T08:00:00.000');
    expect(args('remind me this Wednesday at 6pm to call Bob')!['at'],
        '2026-10-21T18:00:00.000');
    expect(args('remind me on thursday at 11am to call Bob')!['at'],
        '2026-10-15T11:00:00.000');
    // Thursday 9 AM already passed: ask, never jump to next week
    expect(r.fastRoute('remind me on thursday at 9am to call Bob'), isNull);
    expect(r.maybeClarify('remind me on thursday at 9am to call Bob')!.title,
        'call Bob');
    // a weekday that agrees with the date is fine; one that doesn't asks
    expect(args('remind me on Thursday 5 November at 9am to pay')!['at'],
        '2026-11-05T09:00:00.000');
    refused('remind me on Friday 5 November at 9am to pay');
    refused('remind me tomorrow 5 November at 9am to pay');
    refused('remind me next friday at 9am to call Bob');
  });

  test('impossible dates and out-of-range years are never normalized', () {
    for (final say in [
      'remind me on 30 February at 9am to pay',
      'remind me on Feb 29 at 9am to pay', // 2026 is not a leap year
      'remind me on 31 April at 9am to pay',
      'remind me on 0 May at 9am to pay',
      'remind me on 2026-02-30 at 9am to pay',
      'remind me on 2026-13-01 at 9am to pay',
      'remind me on 5 November 2300 at 9am to pay',
      'remind me on 5 November 2024 at 9am to pay',
      'remind me on 10 Nov 5 at 9am to pay', // which number is the day?
      'add task pay on 31 September',
    ]) {
      refused(say);
      expect(r.parseCreate(say)!.unsupported, isTrue, reason: say);
    }
    final leap = RuleEngine(clock: () => DateTime(2027, 6, 1));
    expect(args('remind me on 29 February 2028 at 9am to pay', leap)!['at'],
        '2028-02-29T09:00:00.000');
  });

  test('year boundary: a past named date asks, never rolls into next year', () {
    final nye = RuleEngine(clock: () => DateTime(2026, 12, 31, 22));
    const say = 'remind me on 5 January at 9am to renew';
    expect(nye.parseCreate(say)!.at, DateTime(2026, 1, 5, 9));
    expect(nye.fastRoute(say), isNull);
    final d = nye.maybeClarify(say)!;
    expect(nye.clarifyReason(say), contains('already passed'));
    final again = nye.resolveClarify(d, '5 January')!;
    expect((again.call['text'] as String), contains('already passed'));
    expect(again.keep, isTrue);
    final ok = nye.resolveClarify(d, '5 January 2027')!;
    expect((ok.call['arguments'] as Map)['at'], '2027-01-05T09:00:00.000');
    expect(args('remind me on 5 January 2027 at 9am to renew', nye)!['at'],
        '2027-01-05T09:00:00.000');
    expect(args('remind me tomorrow at 8am to rest', nye)!['at'],
        '2027-01-01T08:00:00.000');
  });

  test('daily at 8:46 AM until 5 November: actual local timing and end', () {
    final p = r.parseDaily(
        'remind me daily at 8:46 AM until 5 November to take medicine')!;
    expect(p.problem, isNull);
    final s = p.schedule!;
    expect((s.hour, s.minute), (8, 46));
    expect(s.first, DateTime(2026, 10, 16, 8, 46),
        reason: "today's 8:46 already passed");
    expect(s.until, DateTime(2026, 11, 5, 8, 46));
    expect(s.rest, 'remind me to take medicine');

    final early = RuleEngine(clock: () => DateTime(2026, 10, 15, 7));
    final e = early
        .parseDaily('every day 8:46am till 5 Nov, take medicine')!
        .schedule!;
    expect((e.first, e.until),
        (DateTime(2026, 10, 15, 8, 46), DateTime(2026, 11, 5, 8, 46)));

    final open =
        r.parseDaily('remind me daily at 7pm until done to stretch')!.schedule!;
    expect((open.first, open.until), (DateTime(2026, 10, 15, 19), null));

    // the same words never become a one-off reminder
    refused('remind me daily at 8:46 AM until 5 November to take medicine');
    expect(r.parseDaily('remind me at 8:46 AM on 5 November to take medicine'),
        isNull);
  });

  test('daily problems ask instead of saving', () {
    for (final say in [
      'remind me daily until 5 November to take medicine', // no time of day
      'remind me daily at 8:46 until 30 February to take medicine',
      'remind me daily at 8:46 until 1 October to take medicine', // past
      'remind me daily at 8:46 until someday to take medicine',
      'remind me daily at 8:46 tomorrow to take medicine',
      'remind me daily morning at 8pm to take medicine',
      'remind me daily until 5 November at 6pm to renew',
      'remind me daily at 8:46am until 5 November at 6pm to renew',
    ]) {
      final p = r.parseDaily(say)!;
      expect(p.schedule, isNull, reason: say);
      expect(p.problem, isNotEmpty, reason: say);
    }
  });

  test('existing today/tomorrow/relative parsing is unchanged', () {
    expect(args('remind me tomorrow at 7 to run')!['at'],
        '2026-10-16T07:00:00.000');
    expect(args('remind me today at 5pm to run')!['at'],
        '2026-10-15T17:00:00.000');
    expect(args('remind me tonight to run')!['at'], '2026-10-15T20:00:00.000');
    expect(args('remind me in 20 minutes to run')!['at'],
        '2026-10-15T10:20:00.000');
    expect(args('remind me tomo morning to run')!['at'],
        '2026-10-16T09:00:00.000');
    expect(args('remind me at 7 to run')!['at'], '2026-10-15T19:00:00.000');
    refused('add task dentist on 12/03');
    refused('add task pay rent in 2 weeks');
  });
}
