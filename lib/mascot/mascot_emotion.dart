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

/// Version of the model's structured mood envelope ([moodContractKey]) and of
/// the stored-record shape. Bumped when the envelope's fields change meaning.
const moodContractVersion = 1;

/// The metadata key inside a plan/reply JSON object that carries the mood.
const moodContractKey = 'emotion';

/// Moods the model may name. `unknown` is an explicit model decision that no
/// listed mood fits; it lands as a known-source record without an emotion.
final moodContractMoods = [
  ...MascotMood.values.map((m) => m.name),
  'unknown',
];

/// The mood fields the app reads out of one submitted user turn, validated
/// against the contract. [mood] is null when the model named `unknown`.
class MoodReading {
  final MascotMood? mood;
  final double intensity;
  final double? confidence;

  /// Model-reported confidence is not a calibrated probability; thresholds
  /// must be chosen from measured device behaviour, not assumed here.
  const MoodReading(
      {this.mood, this.intensity = 0.25, this.confidence});
  /// Validates one decoded `emotion` envelope. Null when the envelope is
  /// malformed (wrong shape, unknown keys, out-of-range or non-finite
  /// numbers): the reading is then unknown, never guessed from text.
  static MoodReading? parse(Object? raw) {
    if (raw is! Map) return null;
    for (final k in raw.keys) {
      if (k != 'mood' && k != 'intensity' && k != 'confidence') return null;
    }
    final moodName = raw['mood'];
    if (moodName is! String || !moodContractMoods.contains(moodName)) {
      return null;
    }
    double? bounded(Object? v) {
      if (v == null) return null;
      if (v is! num || v.isNaN || v.isInfinite || v < 0 || v > 1) return null;
      return v.toDouble();
    }

    final intensity = bounded(raw['intensity']);
    if (intensity == null) return null;
    double? confidence;
    if (raw['confidence'] != null) {
      confidence = bounded(raw['confidence']);
      if (confidence == null) return null;
    }
    final mood =
        moodName == 'unknown' ? null : MascotMood.values.byName(moodName);
    return MoodReading(
        mood: mood, intensity: intensity, confidence: confidence);
  }
}

/// The app's per-turn mood record: what the model proposed for one submitted
/// user turn, after structural validation. [emotion] is null for an unknown
/// or unavailable reading — the UI renders calm and never infers a mood from
/// text itself. Provenance fields make records auditable, storable, and
/// safe to drop when stale.
class TurnMood {
  /// Null = unknown provenance (no valid model reading this turn).
  final MascotEmotion? emotion;
  final double? confidence;
  final String source;

  /// `conversations.session_id` of the turn's chat.
  final String conversationId;

  /// The submitted turn's operation id; a newer turn supersedes older events.
  final String turnId;

  /// `conversations.id` of the turn's user message row, when known.
  final int? messageRowId;

  /// Which model call produced the reading within the turn.
  final String generationId;

  const TurnMood({
    required this.source,
    required this.conversationId,
    required this.turnId,
    required this.generationId,
    this.emotion,
    this.confidence,
    this.messageRowId,
  });

  /// The no-reading state every turn starts from.
  factory TurnMood.unknown(String conversationId, String turnId) => TurnMood(
      source: 'none', conversationId: conversationId, turnId: turnId, generationId: '');

  bool get known => emotion != null;

  /// What the renderer draws: the model's emotion, or plain calm for unknown.
  MascotEmotion get display => emotion ?? MascotEmotion.calm;

  /// Rebuilds a display record from a `message_moods` row (see [MoodRepo]).
  /// Null when the row's mood value is a name outside the contract.
  static TurnMood? fromDbRow(Map<String, Object?> row,
      {required String conversationId}) {
    final name = row['mood'];
    if (name != null &&
        (name is! String || !moodContractMoods.contains(name))) {
      return null;
    }
    final raw = row['intensity'];
    final inRange = raw is num && !raw.isNaN && raw >= 0 && raw <= 1;
    final emotion = name is String && name != 'unknown'
        ? MascotEmotion(
            MascotMood.values.byName(name),
            inRange ? raw.toDouble() : MascotEmotion.calm.intensity)
        : null;
    final confidence = row['confidence'];
    return TurnMood(
      source: row['source'] is String ? row['source'] as String : 'none',
      conversationId: conversationId,
      turnId: '',
      generationId: '',
      emotion: emotion,
      confidence: confidence is num && confidence >= 0 && confidence <= 1
          ? confidence.toDouble()
          : null,
      messageRowId: row['message_id'] is int ? row['message_id'] as int : null,
    );
  }

  @override
  String toString() => 'TurnMood(${emotion?.mood.name ?? 'unknown'}'
      '${confidence == null ? '' : ' c${confidence!.toStringAsFixed(2)}'}'
      ' $source turn:$turnId row:$messageRowId)';
}
