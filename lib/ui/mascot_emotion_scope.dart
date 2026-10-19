import 'package:flutter/widgets.dart';
import '../mascot/mascot_emotion.dart';

/// Shared target for all mascot placements in the active conversation.
class MascotEmotionScope extends InheritedWidget {
  final MascotEmotion emotion;
  const MascotEmotionScope(
      {required this.emotion, required super.child, super.key});
  static MascotEmotion of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MascotEmotionScope>()
          ?.emotion ??
      MascotEmotion.calm;
  @override
  bool updateShouldNotify(MascotEmotionScope oldWidget) =>
      emotion != oldWidget.emotion;
}

/// Renderer contract: blended weights survive interrupted transitions.
/// Gemini should use weight(mood) for poses/colors/motion and intensity for range.
class MascotExpressionFrame {
  final Map<MascotMood, double> weights;
  final double intensity;
  MascotExpressionFrame(Map<MascotMood, double> weights, this.intensity)
      : weights = Map.unmodifiable(weights);
  factory MascotExpressionFrame.fromEmotion(MascotEmotion emotion) =>
      MascotExpressionFrame({emotion.mood: 1}, emotion.intensity);
  double weight(MascotMood mood) => weights[mood] ?? 0;
  static MascotExpressionFrame lerp(
          MascotExpressionFrame a, MascotExpressionFrame b, double t) =>
      MascotExpressionFrame({
        for (final mood in MascotMood.values)
          mood: a.weight(mood) + (b.weight(mood) - a.weight(mood)) * t,
      }, a.intensity + (b.intensity - a.intensity) * t);
}
