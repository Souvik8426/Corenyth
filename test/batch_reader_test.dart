import 'package:assistant/assistant/batch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('screenshot-1 style digest preserves sections and every item', () {
    final result = readBatch('''
**Due soon**
- Sachiv V1 — tomorrow
- ChatGPT Plus cancel on Nov 3
- SurveyMonkey credits — Nov 19
- Post on X and Instagram
- Pay rent
- Send the report
*
**Waiting on you**
- Jaydeb's ₹60 — waiting for your answer
- Aditya's update — already tracked
- Don't notify you about gym
- Email the team
- Book tickets
**Coming up**
- Dispose of the covers at 9 AM and 6 PM
- Visit the office
- Finish the draft
- Buy milk
- Call mom
''')!;
    expect(result.explicit, isFalse);
    expect(result.items, hasLength(16));
    expect(result.items.take(6).map((item) => item.section),
        everyElement('Due soon'));
    expect(result.items.skip(6).take(5).map((item) => item.section),
        everyElement('Waiting on you'));
    expect(result.items.skip(11).map((item) => item.section),
        everyElement('Coming up'));
    expect(result.items[11].text, 'Dispose of the covers at 9 AM and 6 PM');
  });

  test('screenshot-2 style explicit paste has six unclassified items', () {
    final result = readBatch('''
Add these tasks: **Due soon**
- Sachiv V1 — tomorrow
- SurveyMonkey credits — until Nov 19
- Post on X and Instagram — today 5 PM
**Waiting on you**
- Aditya's update — already tracked
- Jaydeb's ₹60 — waiting for your answer
**Coming up**
- Dispose of the covers — daily at 9 AM and 6 PM
''')!;
    expect(result.explicit, isTrue);
    expect(result.items, hasLength(6));
    expect(result.items.first.section, 'Due soon');
    expect(result.items[3].section, 'Waiting on you');
    expect(result.items.last.section, 'Coming up');
  });

  test('B7 splits add buy milk and call mom tomorrow', () {
    final result = readBatch('add buy milk and call mom tomorrow')!;
    expect(result.items.map((item) => item.text),
        ['buy milk', 'call mom tomorrow']);
    expect(result.explicit, isFalse);
    expect(result.items.map((item) => item.section), everyElement(isNull));
  });

  test('B8 keeps negated bullets for caller classification', () {
    final result =
        readBatch("Add these tasks:\n- buy milk\n- don't remind me about gym")!;
    expect(result.explicit, isTrue);
    expect(result.items.map((item) => item.text),
        ['buy milk', "don't remind me about gym"]);
  });

  test('supports all bullet markers and strips markdown and blank lines', () {
    final result = readBatch('''
# **Work**
- **Buy** milk
* __Call__ mom
• #Email team
1. Pay rent
2) Book tickets
*

''')!;
    expect(result.items.map((item) => item.text),
        ['Buy milk', 'Call mom', 'Email team', 'Pay rent', 'Book tickets']);
    expect(result.items.map((item) => item.section), everyElement('Work'));
  });

  for (final count in [12, 20]) {
    test('$count bullet lines are returned without enforcing caller limit', () {
      final result = readBatch(
          List.generate(count, (index) => '- Task ${index + 1}').join('\n'))!;
      expect(maxBatchItems, 10);
      expect(result.items, hasLength(count));
      expect(result.items.last.text, 'Task $count');
    });
  }

  for (final header in [
    'add these tasks:',
    'ADD THE FOLLOWING:',
    'tasks:',
    'remind me about these:',
  ]) {
    test('recognizes explicit header $header', () {
      expect(readBatch('$header\n- buy milk\n- call mom')!.explicit, isTrue);
    });
  }

  for (final join in ['and', 'then', 'also', 'plus', 'and then', 'and also']) {
    test('splits rule-engine verb join $join', () {
      final result = readBatch('buy milk $join call mom tomorrow')!;
      expect(result.items.map((item) => item.text),
          ['buy milk', 'call mom tomorrow']);
    });
  }

  test('splits optional commitment phrasing and multiple joins', () {
    final result =
        readBatch('buy milk and I also need to call mom then pay rent')!;
    expect(result.items.map((item) => item.text),
        ['buy milk', 'call mom', 'pay rent']);
  });

  test('single sentences, empty input and lone bullets return null', () {
    for (final text in [
      'call mom and dad',
      'Buy milk tomorrow.',
      '- buy milk',
      'Add these tasks:\n- buy milk',
      '*\n\n**Due soon**',
      '',
      'buy milk\ncall mom',
    ]) {
      expect(readBatch(text), isNull, reason: text);
    }
  });

  test('does not apply short-message conjunction fallback to long prose', () {
    expect(readBatch('${'Some context. ' * 50}buy milk and call mom'), isNull);
  });
}
