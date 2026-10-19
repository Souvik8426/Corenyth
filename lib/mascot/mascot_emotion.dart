import '../data/repos.dart';

/// Supportive is the response to sadness; concerned means steady attentiveness.
enum MascotMood { calm, happy, excited, supportive, concerned, curious }

class MascotEmotion {
  final MascotMood mood;
  final double intensity;
  const MascotEmotion(this.mood, this.intensity)
      : assert(intensity >= 0 && intensity <= 1);
  static const calm = MascotEmotion(MascotMood.calm, 0.25);

  @override
  bool operator ==(Object other) =>
      other is MascotEmotion &&
      mood == other.mood &&
      intensity == other.intensity;
  @override
  int get hashCode => Object.hash(mood, intensity);
}

/// A deliberately conservative English heuristic, not a psychological assessment.
/// Replays up to eight user turns: deterministic across rebuilds/history loads,
/// no network/model calls, timers, persistence, or effects on assistant answers.
class MascotEmotionInterpreter {
  const MascotEmotionInterpreter();

  MascotEmotion interpret(Iterable<Message> messages) {
    final recent = <String>[];
    final transcript = messages is List<Message> ? messages : messages.toList();
    for (final message in transcript.reversed) {
      if (message.role != 'user' || message.kind != null) continue;
      recent.add(message.content);
      if (recent.length == 8) break;
    }
    var mood = MascotMood.calm;
    var strength = 0.25;
    MascotMood? pending;
    var repeats = 0;
    for (final text in recent.reversed) {
      final cue = _cue(text);
      if (cue == null) {
        strength *= 0.65;
        if (strength < 0.2) mood = MascotMood.calm;
        pending = null;
        repeats = 0;
        continue;
      }
      final urgent =
          cue.mood == MascotMood.supportive || cue.mood == MascotMood.concerned;
      if (cue.mood == mood || mood == MascotMood.calm || urgent) {
        mood = cue.mood;
        strength = (strength * 0.35 + cue.intensity * 0.65).clamp(0.0, 1.0);
        pending = null;
        repeats = 0;
      } else {
        repeats = pending == cue.mood ? repeats + 1 : 1;
        pending = cue.mood;
        // One cheerful remark must not abruptly erase a difficult conversation.
        if (repeats >= 2) {
          mood = cue.mood;
          strength = cue.intensity * 0.8;
          pending = null;
          repeats = 0;
        }
      }
    }
    if (mood == MascotMood.calm) return MascotEmotion.calm;
    return MascotEmotion(mood, (strength * 20).round() / 20);
  }

  MascotEmotion? _cue(String raw) {
    var text = raw.length > 4000 ? raw.substring(0, 4000) : raw;
    text = text.toLowerCase().replaceAll('’', "'");
    // Quoted/code examples and hypothetical clauses do not describe the user.
    text = text.replaceAll(
        RegExp(r'```[\s\S]*?```|`[^`]*`|"[^"\n]*"|“[^”]*”'), ' ');
    text = text
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('>'))
        .join(' ');
    final clauses = text.split(RegExp(r'[.!?;\n]|\bbut\b|\bhowever\b'));
    final found = <MascotEmotion>[];
    for (var clause in clauses) {
      if (RegExp(
              r'\b(if|imagine|hypothetically|suppose|example|story|character|movie|quote|translate)\b')
          .hasMatch(clause)) continue;
      // Remove common negated feelings before matching positive evidence.
      clause = clause.replaceAll(
          RegExp(
              r"\b(?:not|never|no longer|don't feel|do not feel|am not|isn't|wasn't)\s+(?:really\s+|very\s+|so\s+)?(?:happy|sad|excited|worried|anxious|scared|depressed|lonely|upset|thrilled|overwhelmed)\b"),
          ' ');
      if (_has(clause, r"\b(?:i(?:'m| am| feel| have been)|my|we|this is)\b") &&
              _has(clause,
                  r'\b(worried|anxious|scared|terrified|unsafe|overwhelmed|panic|serious|emergency|in danger)\b') ||
          _has(clause, r"\bi (?:want to die|can't go on|cannot go on)\b")) {
        found.add(const MascotEmotion(MascotMood.concerned, 0.85));
      } else if (_has(clause, r"\b(?:i(?:'m| am| feel| have been)|my)\b") &&
          _has(clause,
              r'\b(sad|depressed|lonely|grieving|heartbroken|upset|died|passed away|failed|crying|lost (?:my|a) (?:dad|mom|father|mother|friend|pet)|rough day|hard day)\b')) {
        found.add(const MascotEmotion(MascotMood.supportive, 0.8));
      } else if (_has(clause, r"\b(?:i(?:'m| am| feel)|we|my)\b") &&
          _has(clause,
              r'\b(excited|thrilled|ecstatic|won|got the job|got promoted|passed my|nailed it)\b')) {
        found.add(const MascotEmotion(MascotMood.excited, 0.95));
      } else if (_has(clause, r"\b(?:i(?:'m| am| feel)|we|my|that|this)\b") &&
          _has(clause,
              r'\b(happy|proud|grateful|delighted|great news|wonderful|awesome|love it)\b')) {
        found.add(const MascotEmotion(MascotMood.happy, 0.75));
      } else if (_has(clause,
          r"\b(curious|i wonder|help me understand|how does|why does|let's explore)\b")) {
        found.add(const MascotEmotion(MascotMood.curious, 0.55));
      }
    }
    // Mixed messages favor care; enthusiasm cannot outweigh distress.
    for (final mood in [
      MascotMood.concerned,
      MascotMood.supportive,
      MascotMood.excited,
      MascotMood.happy,
      MascotMood.curious
    ]) {
      for (final cue in found) {
        if (cue.mood == mood) return cue;
      }
    }
    return null;
  }

  bool _has(String text, String pattern) => RegExp(pattern).hasMatch(text);
}
