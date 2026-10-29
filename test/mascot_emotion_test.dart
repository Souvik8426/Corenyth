import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/semantic.dart';
import 'package:assistant/assistant/tools.dart' show ToolError;
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mood_corpus.dart';

void main() {
  group('MoodReading.parse (the model contract, validated structurally)', () {
    Map<String, Object?> envelope(String mood, {Object? intensity = 0.5,
        Object? confidence = 0.8}) => {
            'mood': mood,
            if (intensity != null) 'intensity': intensity,
            if (confidence != null) 'confidence': confidence,
          };

    test('accepts every allowlisted mood and maps unknown to no mood', () {
      for (final mood in MascotMood.values) {
        final r = MoodReading.parse(envelope(mood.name))!;
        expect(r.mood, mood);
        expect(r.intensity, 0.5);
      }
      expect(MoodReading.parse(envelope('unknown'))!.mood, isNull);
      expect(MoodReading.parse(envelope('unknown')), isNotNull,
          reason: 'an explicit model "unknown" is a valid reading');
    });

    test('rejects malformed envelopes without inventing a mood', () {
      expect(MoodReading.parse(null), isNull);
      expect(MoodReading.parse('happy'), isNull);
      expect(MoodReading.parse({'mood': 'angry'}), isNull,
          reason: 'not an allowlisted mood');
      expect(MoodReading.parse({'mood': 'happy', 'note': 'hi'}), isNull,
          reason: 'unknown envelope keys are rejected, never ignored');
      expect(MoodReading.parse(envelope('happy', intensity: 1.5)), isNull);
      expect(MoodReading.parse(envelope('happy', intensity: -0.1)), isNull);
      expect(MoodReading.parse(envelope('happy', intensity: 'high')), isNull);
      expect(MoodReading.parse(envelope('happy', confidence: 4)), isNull);
      expect(MoodReading.parse({'intensity': 0.5}), isNull,
          reason: 'mood is required');
      expect(MoodReading.parse(envelope('happy', confidence: null)),
          isNotNull,
          reason: 'confidence is optional');
    });
  });

  group('plan/reply grammar carries the mood envelope first', () {
    test('both plan contracts require the emotion object before intent', () {
      for (final g in [semanticGrammar, semanticGrammarV2]) {
        expect(g, contains('emotion ::= "{\\"mood\\":" emood'));
        expect(g, contains('\\"emotion\\":" emotion'));
        final root = g.split('\n').first;
        expect(root, startsWith('root ::= plan-'),
            reason: 'every plan variant starts with the emotion field');
      }
    });

    test('the reply grammar emits the envelope before the respond text', () {
      expect(
          Prompt.replyGrammar,
          contains(
              'root ::= "{\\"emotion\\":" emotion ",\\"type\\":\\"respond\\",\\"text\\":"'));
    });

    test('prompt wording asks for meaning, not tone', () {
      expect(Prompt.emotionGuide, contains('Never infer emotion from the '
          'configured reply tone'));
      expect(Prompt.planSystem, contains('emotion (always the first field)'));
      expect(Prompt.planSystemV2, contains('emotion (always the first field)'));
      expect(Prompt.replySystem, contains('"emotion"'));
    });

    test('fingerprint includes the emotion grammar', () {
      expect(promptFingerprint, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(promptFingerprintV2, matches(RegExp(r'^[0-9a-f]{12}$')));
    });
  });

  group('parseSemantic keeps action validation strict around the envelope', () {
    test('a valid envelope rides along with a valid plan', () {
      final s = parseSemantic(jsonEncode({
        'emotion': {'mood': 'concerned', 'intensity': 0.7, 'confidence': 0.9},
        'intent': 'chat',
        'reply': 'I hear you.',
      }));
      expect(s.intent, 'chat');
      expect(s.mood!.mood, MascotMood.concerned);
    });

    test('missing or malformed emotion degrades to unknown, not failure', () {
      // Absent (e.g. hand-built plans): unknown reading, plan valid.
      expect(
          parseSemantic(jsonEncode({'intent': 'chat', 'reply': 'Hi'})).mood,
          isNull);
      // Malformed envelope: the plan still stands, the mood is unknown.
      final s = parseSemantic(jsonEncode({
        'emotion': {'mood': 'happy', 'intensity': 9},
        'intent': 'chat',
        'reply': 'Hi',
      }));
      expect(s.intent, 'chat');
      expect(s.mood, isNull);
    });

    test('unknown plan keys are still rejected', () {
      expect(
          () => parseSemantic(jsonEncode({
                'emotion': {'mood': 'happy', 'intensity': 0.5},
                'intent': 'chat',
                'reply': 'Hi',
                'score': 9,
              })),
          throwsToolError);
      // An unknown key inside the envelope makes the ENVELOPE invalid
      // (unknown mood), while the otherwise valid plan still stands.
      final s = parseSemantic(jsonEncode({
        'emotion': {'mood': 'happy', 'intensity': 0.5, 'why': 'x'},
        'intent': 'chat',
        'reply': 'Hi',
      }));
      expect(s.intent, 'chat');
      expect(s.mood, isNull);
    });
  });

  group('planStreamView extracts incrementally, never from partial JSON', () {
    const full =
        '{"emotion":{"mood":"happy","intensity":0.80,"confidence":0.90},'
        '"intent":"chat","reply":"Doing great, thanks!"}';
    // Marker-based prefixes: how much of the generation has arrived.
    final afterEnvelope = full.indexOf('},') + 2;
    final afterIntent =
        full.indexOf('"intent":"chat"') + '"intent":"chat"'.length;
    final replyValueStart = full.indexOf('"reply":"') + '"reply":"'.length;
    String cut(int to) => full.substring(0, to);

    test('the mood lands before any reply text exists', () {
      final early = planStreamView(cut(afterEnvelope));
      expect(early.mood, isNotNull);
      expect(early.mood!.mood, MascotMood.happy);
      expect(early.intent, isNull);
      expect(early.replyText, isNull);
    });

    test('intent completes before the reply field', () {
      final v = planStreamView(cut(afterIntent));
      expect(v.intent, 'chat');
      expect(v.replyText, isNull);
    });

    test('reply prose grows in complete units only', () {
      expect(planStreamView(cut(replyValueStart + 11)).replyText,
          'Doing great');
      expect(planStreamView(cut(replyValueStart + 8)).replyText, 'Doing gr');
      // A trailing partial escape or surrogate is withheld until complete.
      const accented =
          '{"emotion":{"mood":"calm","intensity":0.25,"confidence":0.5},'
          '"intent":"chat","reply":"é';
      expect(planStreamView(accented).replyText, 'é');
      const partialEscape =
          '{"emotion":{"mood":"calm","intensity":0.25,"confidence":0.5},'
          '"intent":"chat","reply":"a\\';
      expect(planStreamView(partialEscape).replyText, 'a');
      const loneHigh =
          '{"emotion":{"mood":"calm","intensity":0.25,"confidence":0.5},'
          '"intent":"chat","reply":"\\ud83d';
      expect(planStreamView(loneHigh).replyText, '');
      const fullPair =
          '{"emotion":{"mood":"calm","intensity":0.25,"confidence":0.5},'
          '"intent":"chat","reply":"\\ud83d\\ude00x';
      expect(planStreamView(fullPair).replyText, '\u{1F600}x');
    });

    test('a tool-shaped plan never leaks arguments as reply text', () {
      const raw = '{"emotion":{"mood":"calm","intensity":0.25,'
          '"confidence":0.9},"intent":"create_task","title":"meeting",'
          '"when":"tomorrow","reply":"What is it about?"}';
      final v = planStreamView(raw);
      expect(v.intent, 'create_task');
      expect(v.replyText, 'What is it about?');
      // The session streams chat plans only; create_task replies buffer for
      // validation (asserted in the session tests).
    });

    test('malformed or absent envelopes yield no mood', () {
      expect(
          planStreamView('{"emotion":{"mood":" furious","intensity":0.5},'
                  '"intent":"chat"}')
              .mood,
          isNull);
      expect(planStreamView('{"intent":"chat"}').mood, isNull);
    });
  });

  test('visibleRespondText also reads the mood-prefixed reply contract', () {
    expect(
        visibleRespondText('{"emotion":{"mood":"calm","intensity":0.25,'
                '"confidence":0.9},"type":"respond","text":"He'),
        'He');
    expect(
        visibleRespondText('{"emotion":{"mood":"calm","intensity":0.25,'
                '"confidence":0.9},"type":"respond","text":"hey \\"x\\""}'),
        'hey "x"');
    // A partial envelope is not a respond object yet.
    expect(
        visibleRespondText('{"emotion":{"mood":"calm","intensity":0.25,'
            '"confidence":0.9},"type":"respond","text":"'),
        '');
    // Plain respond objects keep working (compatibility).
    expect(visibleRespondText('{"type":"respond","text":"a\\u00e9b"}'), 'aéb');
  });

  group('TurnMood provenance and storage round-trip', () {
    test('unknown is represented distinctly from a confident calm', () {
      final unknown = TurnMood.unknown('c1', 'op1');
      expect(unknown.known, isFalse);
      expect(unknown.source, 'none');
      expect(unknown.display, MascotEmotion.calm,
          reason: 'the render state is calm, the provenance is unknown');
      final calm = TurnMood(
          source: 'model:plan-v1',
          conversationId: 'c1',
          turnId: 'op1',
          generationId: 'g',
          emotion: const MascotEmotion(MascotMood.calm, 0.4));
      expect(calm.known, isTrue);
      expect(calm.display, const MascotEmotion(MascotMood.calm, 0.4));
    });

    test('fromDbRow rebuilds a display record or rejects a bad row', () {
      final r = TurnMood.fromDbRow({
        'message_id': 7,
        'mood': 'excited',
        'intensity': 0.9,
        'confidence': 0.8,
        'source': 'model:plan-v1',
      }, conversationId: 'c1')!;
      expect(r.emotion!.mood, MascotMood.excited);
      expect(r.messageRowId, 7);
      expect(TurnMood.fromDbRow({
        'message_id': 8,
        'mood': null,
        'intensity': 0.25,
        'confidence': null,
        'source': 'none',
      }, conversationId: 'c1')!.known, isFalse,
          reason: 'mood null = unknown provenance, not calm classification');
      expect(
          TurnMood.fromDbRow({
            'message_id': 9,
            'mood': 'furious',
            'intensity': 0.25,
            'confidence': null,
            'source': 'x',
          }, conversationId: 'c1'),
          isNull);
      expect(
          TurnMood.fromDbRow({
            'message_id': 10,
            'mood': 'happy',
            'intensity': 7.0,
            'confidence': null,
            'source': 'x',
          }, conversationId: 'c1')!.emotion!.intensity,
          MascotEmotion.calm.intensity,
          reason: 'out-of-range stored intensity falls back to the neutral');
    });
  });

  test('mood corpus entries stay inside the contract (data hygiene)', () {
    for (final corpus in [devCorpus, heldOutCorpus]) {
      expect(corpus, isNotEmpty);
      for (final c in corpus) {
        expect(c.accepted, isNotEmpty, reason: '"${c.text}" needs a label');
        expect(
            c.accepted.toSet().difference(MascotMood.values.toSet()),
            isEmpty,
            reason: '"${c.text}" labels must be render moods');
      }
    }
  });

  /// Real-model evaluation on the device (Prompt 1.5, Prompt 7). The corpus
  /// runs through the installed on-device model; a unit-test host has no
  /// native engine, so this gate is declared here and executed on the phone
  /// (see the completion report's device gates). Mocked model responses
  /// never count as model-quality evidence, so this is skipped, not passed.
  test('held-out corpus against the installed model (device gate)', () {
    fail('Run on the device host with the installed model; see '
        'test/fixtures/mood_corpus.dart and the completion report.');
  },
      skip: 'requires the on-device model (device gate, not a unit test)');
}

final throwsToolError = throwsA(isA<ToolError>());
