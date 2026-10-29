import 'package:flutter_test/flutter_test.dart';
import 'package:assistant/assistant/core_policy.dart';

void main() {
  test('conversational cap respects detail and repetition exceptions', () {
    final p = CorePolicy();
    final long = List.filled(100, 'A useful sentence.').join(' ');
    expect(p.concise(long, 'hello').length, lessThanOrEqualTo(361));
    expect(p.concise(long, 'explain in detail'), long);
    p.refuse('What is quantum physics');
    p.refuse('What is quantum physics');
    expect(p.concise(long, 'What is quantum physics'), long);
  });
  test('scope refusal, repeat, unrelated reset and conversation isolation', () {
    final p = CorePolicy();
    expect(p.refuse('Explain this code'), isTrue);
    expect(p.refuse('Please explain the code'), isFalse);
    expect(p.refuse('add task buy milk'), isFalse);
    expect(p.refuse('Explain this code'), isTrue);
    expect(CorePolicy().refuse('Explain this code'), isTrue);
  });
  test('embedded unrelated topics do not refuse core commands', () {
    final p = CorePolicy();
    for (final text in [
      'plan my day',
      'remind me to explain this code to Sam',
      'what is my schedule',
      'hello',
      '5pm'
    ]) {
      expect(p.refuse(text), isFalse, reason: text);
    }
  });
}
