import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/ui/mascot_emotion_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const interpreter = MascotEmotionInterpreter();
  MascotEmotion mood(List<String> turns) =>
      interpreter.interpret(turns.map((text) => Message('user', text)));

  for (final (text, expected) in [
    ('I feel happy today', MascotMood.happy),
    ("I'm excited, I got the job!", MascotMood.excited),
    ('I feel sad', MascotMood.supportive),
    ("I'm worried about my results", MascotMood.concerned),
    ('My father passed away', MascotMood.supportive),
    ('Help me understand how this works', MascotMood.curious),
    ('Set a timer for five minutes', MascotMood.calm),
    ('I am not happy', MascotMood.calm),
    ("I'm not worried", MascotMood.calm),
    ('If I feel sad, what would you do?', MascotMood.calm),
    ('The movie character is sad', MascotMood.calm),
    ('Translate "I feel sad"', MascotMood.calm),
    ('> I feel sad', MascotMood.calm),
    ('`I feel sad`', MascotMood.calm),
    ('I lost my keys', MascotMood.calm),
    ("I'm happy but I'm scared", MascotMood.concerned),
  ]) {
    test('classifies $text', () => expect(mood([text]).mood, expected));
  }

  test('assistant text, system text and proactive content do not steer mood',
      () {
    final base = [Message('user', 'I feel sad')];
    expect(
        interpreter.interpret([
          ...base,
          Message('assistant', "I'm excited!"),
          Message('system', 'I feel happy'),
          Message('user', 'I feel happy', kind: 'reminder'),
        ]),
        interpreter.interpret(base));
  });
  test('sadness overrides celebration immediately', () {
    expect(mood(['I feel happy', 'I feel sad']).mood, MascotMood.supportive);
  });
  test('one positive remark does not erase distress, repeated recovery does',
      () {
    expect(mood(['I feel sad', 'I feel happy']).mood, MascotMood.supportive);
    expect(mood(['I feel sad', 'I feel happy', 'I feel happy']).mood,
        MascotMood.happy);
  });
  test('neutral turns gradually settle the mood', () {
    expect(mood(['I feel sad', 'Okay']).mood, MascotMood.supportive);
    expect(mood(['I feel sad', ...List.filled(5, 'Okay')]), MascotEmotion.calm);
  });
  test('history replay is stable and new conversation resets', () {
    final turns = ['I feel happy', 'I feel sad', 'Okay'];
    expect(mood(turns), mood(turns));
    expect(mood([]), MascotEmotion.calm);
    expect(
        mood(['I feel sad', ...List.filled(8, 'Hello')]), MascotEmotion.calm);
  });
  test('blending preserves continuity when interrupted', () {
    final a = MascotExpressionFrame.fromEmotion(MascotEmotion.calm);
    final b = MascotExpressionFrame.fromEmotion(
        const MascotEmotion(MascotMood.happy, 0.8));
    final halfway = MascotExpressionFrame.lerp(a, b, 0.5);
    final c = MascotExpressionFrame.fromEmotion(
        const MascotEmotion(MascotMood.supportive, 0.7));
    final interrupted = MascotExpressionFrame.lerp(halfway, c, 0);
    expect(interrupted.weights, halfway.weights);
    expect(interrupted.intensity, halfway.intensity);
    expect(
        MascotExpressionFrame.lerp(halfway, c, 1).weight(MascotMood.supportive),
        1);
    expect(() => halfway.weights[MascotMood.calm] = 1, throwsUnsupportedError);
  });
}
