// Exports the app's fixed prompts and a few rendered samples so
// training/build_dataset.py can check its renderer byte for byte.
//
//   flutter test training/export_prompts_test.dart \
//     --dart-define=EXPORT_PATH=/absolute/path/prompt_export.json
import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/personalities.dart';
import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export prompts for training', () {
    const path = String.fromEnvironment('EXPORT_PATH');
    expect(path, isNotEmpty, reason: 'pass --dart-define=EXPORT_PATH=...');
    final now = DateTime(2026, 10, 20, 14, 5);
    final planFull = Prompt(PromptKind.plan, 'remind me to call mom at 5pm',
            tone: 'loving',
            tasks: '#3 buy milk\n#7 meeting (due tomorrow (Wed 21 Oct) at 3:00 PM)',
            personalContext:
                'The user is Asha and works as teacher. Preferred assistant tone: loving.',
            pending: 'task "dentist" still needs a time',
            context: 'Last task mentioned: #3 buy milk',
            memories: const ['User likes tea'],
            now: now)
        .render();
    final planEmpty = Prompt(PromptKind.plan, 'hi',
            tone: 'professional',
            tasks: '(none)',
            personalContext: 'Preferred assistant tone: professional.',
            now: DateTime(2026, 1, 4, 9, 0))
        .render();
    final planNoTone = Prompt(PromptKind.plan, 'hi',
            tasks: '(none)', now: DateTime(2026, 1, 4, 9, 0))
        .render();
    final replyHistory = Prompt(PromptKind.reply, 'It went well, thanks',
            tone: 'caring',
            history: [
              Message('user', 'I have a big meeting at 3'),
              Message('assistant', 'Good luck, you are ready for it.'),
            ],
            context: 'Last task mentioned: #7 meeting',
            personalContext: 'The user is Ravi. Preferred assistant tone: caring.',
            now: now)
        .render();
    final replyPlain = Prompt(PromptKind.reply, 'finally fixed my glasses',
            tone: 'friendly', now: DateTime(2026, 3, 2, 18, 30))
        .render();
    File(path).writeAsStringSync(jsonEncode({
      'planSystem': Prompt.planSystem,
      'replySystem': Prompt.replySystem,
      'toneGuide': Prompt.toneGuide,
      'emotionGuide': Prompt.emotionGuide,
      'toneStyles': Prompt.toneStyles,
      'personalities': Personalities.instructions,
      'samples': {
        'planFull': planFull,
        'planEmpty': planEmpty,
        'planNoTone': planNoTone,
        'replyHistory': replyHistory,
        'replyPlain': replyPlain,
      },
    }));
  });
}
