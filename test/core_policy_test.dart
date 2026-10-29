import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assistant/assistant/core_policy.dart';

void main() {
  test('conversational cap respects detail and repetition exceptions', () {
    final p = CorePolicy();
    final long = List.filled(100, 'A useful sentence.').join(' ');
    expect(p.concise(long, 'hello').characters.length, lessThanOrEqualTo(360));
    expect(p.concise(long, 'explain in detail'), long);
    p.refuse('What is quantum physics');
    p.refuse('What is quantum physics');
    expect(p.concise(long, 'What is quantum physics'), long);
  });

  test('scope refusal, repeat, unrelated reset and conversation isolation', () {
    final store = CorePolicyStore();
    final a = CorePolicy(store: store, chatId: 'a');
    final b = CorePolicy(store: store, chatId: 'b');
    expect(a.evaluate('Explain this code'), ScopeDecision.refuse);
    expect(a.evaluate('Please explain the code'), ScopeDecision.persistedOutside);
    expect(a.evaluate('add task buy milk'), ScopeDecision.core);
    expect(a.evaluate('Explain this code'), ScopeDecision.refuse);
    expect(b.evaluate('Explain this code'), ScopeDecision.refuse);
    expect(CorePolicy().evaluate('Explain this code'), ScopeDecision.refuse);
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

  test('arithmetic and pending-like answers clear outside topic', () {
    final p = CorePolicy();
    expect(p.evaluate('What is quantum physics'), ScopeDecision.refuse);
    p.noteCoreTurn();
    expect(p.evaluate('What is quantum physics'), ScopeDecision.refuse);
  });

  test('empty topic tokens are never similar', () {
    final p = CorePolicy();
    expect(p.evaluate('What is ??'), ScopeDecision.refuse);
    // A second empty-token outside request must refuse again, not persist.
    expect(p.evaluate('Who is !!!'), ScopeDecision.refuse);
  });

  test('explicit persistence phrase only works after a refusal', () {
    final p = CorePolicy();
    expect(p.evaluate('please answer anyway'), ScopeDecision.uncertain);
    expect(p.evaluate('Explain this code'), ScopeDecision.refuse);
    expect(p.evaluate('please answer anyway'), ScopeDecision.persistedOutside);
  });

  test('chat-scoped store survives session reconstruction semantics', () {
    final store = CorePolicyStore();
    final first = CorePolicy(store: store, chatId: 'chat-1');
    expect(first.evaluate('Explain this code'), ScopeDecision.refuse);
    final again = CorePolicy(store: store, chatId: 'chat-1');
    expect(again.evaluate('Please explain the code'), ScopeDecision.persistedOutside);
  });

  test('grapheme budget counts clusters and includes ellipsis', () {
    final p = CorePolicy();
    // 361 family-emoji grapheme clusters (each may be multiple code points).
    final long = List.filled(400, '👨‍👩‍👧‍👦').join();
    final out = p.concise(long, 'hello');
    expect(out.characters.length, lessThanOrEqualTo(360));
    expect(out.endsWith('…'), isTrue);
  });
}
