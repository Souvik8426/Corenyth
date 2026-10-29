import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/personalities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all four personalities survive trimming in plan and reply requests',
      () {
    for (final kind in [PromptKind.plan, PromptKind.reply]) {
      for (final tone in Personalities.names) {
        final prompt = Prompt(kind, 'I had a rough day',
            tone: tone, personalContext: 'Optional profile context');
        for (final candidate in prompt.candidates()) {
          expect(candidate, contains(Personalities.instructions[tone]!));
          expect(candidate, contains('Reply tone: $tone'));
        }
      }
    }
  });
  test('switching personality changes model instructions for the same input',
      () {
    final now = DateTime(2026, 10, 29);
    final prompts = Personalities.names.map((tone) =>
        Prompt(PromptKind.reply, 'Hello', tone: tone).render(now: now));
    expect(prompts.toSet(), hasLength(4));
  });
  test('legacy profiles map to supported personalities', () {
    expect(Personalities.canonical('calm'), 'caring');
    expect(Personalities.canonical('mature'), 'professional');
    expect(Personalities.canonical('playful'), 'friendly');
    expect(Personalities.canonical('cheerful'), 'friendly');
    expect(Personalities.canonical(null), 'friendly');
  });
}
