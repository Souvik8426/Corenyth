import '../mascot/mascot_emotion.dart';
import 'mascot_emotion_scope.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Native rendition of TeriBehenKaPortfolio's MeshGradientSVG character.
/// The original silhouette, 2.8s float/stretch, 3s blink and bounded gaze
/// are retained; layered radial shaders replace the browser mesh shader.
class GhostMascot extends StatefulWidget {
  final double size;
  final bool animated;
  const GhostMascot({this.size = 120, this.animated = true, super.key});

  @override
  State<GhostMascot> createState() => _GhostMascotState();
}

class _GhostMascotState extends State<GhostMascot>
    with TickerProviderStateMixin {
  final _anchor = GlobalKey();
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: const Duration(seconds: 42));
  late final AnimationController _transition = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _bounce = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));
  MascotEmotion _emotion = MascotEmotion.calm;
  MascotExpressionFrame _from =
      MascotExpressionFrame.fromEmotion(MascotEmotion.calm);
  MascotExpressionFrame _to =
      MascotExpressionFrame.fromEmotion(MascotEmotion.calm);
  MascotExpressionFrame get _expression => MascotExpressionFrame.lerp(
      _from, _to, Curves.easeInOut.transform(_transition.value));
  Offset _gaze = Offset.zero;
  Offset _target = Offset.zero;
  double _previous = 0;
  bool _motion = false;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_track);
    _clock.addListener(_follow);
  }

  void _track(PointerEvent event) {
    if (!_motion ||
        (event is! PointerHoverEvent &&
            event is! PointerMoveEvent &&
            event is! PointerDownEvent)) return;
    final box = _anchor.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final point =
        box.globalToLocal(event.position) - box.size.center(Offset.zero);
    _target = Offset((point.dx * 0.08).clamp(-8, 8).toDouble(),
        (point.dy * 0.08).clamp(-8, 8).toDouble());
  }

  void _follow() {
    final now = _clock.value * 42;
    final rawDt = now >= _previous ? now - _previous : (42 - _previous) + now;
    final dt = rawDt.clamp(0.0, 0.05);
    _previous = now;
    _gaze = Offset.lerp(_gaze, _target, 1 - math.exp(-12 * dt))!;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
    final emotion = MascotEmotionScope.of(context);
    if (emotion != _emotion) {
      final enteringExcited = emotion.mood == MascotMood.excited &&
          _emotion.mood != MascotMood.excited;
      _from = _expression;
      _emotion = emotion;
      _to = MascotExpressionFrame.fromEmotion(emotion);
      if (!MediaQuery.disableAnimationsOf(context) &&
          TickerMode.valuesOf(context).enabled) {
        _transition.forward(from: 0);
        if (enteringExcited && _motion) {
          _bounce.forward(from: 0);
        }
      } else {
        _transition.value = 1;
        _bounce.stop();
        _bounce.value = 0;
      }
    }
  }

  @override
  void didUpdateWidget(covariant GhostMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  void _updateMotion() {
    _motion = widget.animated &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_motion) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
      _bounce.stop();
      _bounce.value = 0;
      if (MediaQuery.disableAnimationsOf(context) ||
          !TickerMode.valuesOf(context).enabled) {
        _transition.value = 1;
      }
      _gaze = _target = Offset.zero;
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_track);
    _clock.dispose();
    _transition.dispose();
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        image: true,
        label: 'Corenyth ghost mascot',
        value: _emotion.mood.name,
        child: RepaintBoundary(
          child: SizedBox(
            key: _anchor,
            width: widget.size,
            height: widget.size * 1.35,
            child: CustomPaint(
                painter: _GhostPainter(
                    clock: _clock,
                    gaze: () => _gaze,
                    animated: _motion,
                    transition: _transition,
                    bounce: _bounce,
                    expression: () => _expression)),
          ),
        ),
      );
}

class _GhostPainter extends CustomPainter {
  final Animation<double> clock;
  final Offset Function() gaze;
  final bool animated;
  final Animation<double> transition;
  final Animation<double> bounce;
  final MascotExpressionFrame Function() expression;

  _GhostPainter({
    required this.clock,
    required this.gaze,
    required this.animated,
    required this.transition,
    this.bounce = const AlwaysStoppedAnimation<double>(0),
    required this.expression,
  }) : super(repaint: Listenable.merge([clock, transition, bounce]));

  static Path _buildBodyPath() => Path()
    ..moveTo(230.809, 115.385)
    ..lineTo(230.809, 249.411)
    ..cubicTo(230.809, 269.923, 214.985, 287.282, 194.495, 288.411)
    ..cubicTo(184.544, 288.949, 175.364, 285.718, 168.26, 280)
    ..cubicTo(159.746, 273.154, 147.769, 273.461, 139.178, 280.23)
    ..cubicTo(132.638, 285.384, 124.381, 288.462, 115.379, 288.462)
    ..cubicTo(106.377, 288.462, 98.1451, 285.384, 91.6055, 280.23)
    ..cubicTo(82.912, 273.385, 70.9353, 273.385, 62.2415, 280.23)
    ..cubicTo(55.7532, 285.334, 47.598, 288.411, 38.7246, 288.462)
    ..cubicTo(17.4132, 288.615, 0, 270.667, 0, 249.359)
    ..lineTo(0, 115.385)
    ..cubicTo(0, 51.6667, 51.6756, 0, 115.404, 0)
    ..cubicTo(179.134, 0, 230.809, 51.6667, 230.809, 115.385)
    ..close();

  static final Path _bodyPath = _buildBodyPath();

  @override
  void paint(Canvas canvas, Size size) {
    final frame = expression();
    final intensity = frame.intensity.clamp(0.0, 1.0);
    // Smooth monotonic expressive scaling from 0..1 intensity so default
    // interpreter intensities (0.55..0.95) are clearly legible while still
    // scaling proportionally across the full 0..1 range.
    final expressiveness =
        0.25 * intensity + 0.75 * math.sqrt(intensity);

    final wCalm = frame.weight(MascotMood.calm);
    final happy = frame.weight(MascotMood.happy) * expressiveness;
    final excited = frame.weight(MascotMood.excited) * expressiveness;
    final supportive = frame.weight(MascotMood.supportive) * expressiveness;
    final concerned = frame.weight(MascotMood.concerned) * expressiveness;
    final curious = frame.weight(MascotMood.curious) * expressiveness;

    final t = animated ? clock.value * 42 : 0.0;

    // Harmonic oscillators that all divide the 42-second loop cleanly,
    // ensuring continuous phase across mood transitions without resetting clock.
    final waveCalm = (1 - math.cos(t * 2 * math.pi / 2.8)) / 2; // 15 cycles
    final waveBuoyant = (1 - math.cos(t * 2 * math.pi / 2.1)) / 2; // 20 cycles
    final waveFast = (1 - math.cos(t * 2 * math.pi / 1.68)) / 2; // 25 cycles
    final waveSlow = (1 - math.cos(t * 2 * math.pi / 4.2)) / 2; // 10 cycles
    final waveCurious = (1 - math.cos(t * 2 * math.pi / 3.0)) / 2; // 14 cycles
    final swaySignal = animated ? math.sin(t * 2 * math.pi / 3.5) : 0.0; // 12 cycles
    final searchSignal = animated ? math.sin(t * 2 * math.pi / 2.8) : 0.0;

    final activeTotal = happy + excited + supportive + concerned + curious;
    final calmShare = math.max(0.0, 1.0 - activeTotal) + wCalm * 0.15;
    final waveNorm = calmShare + activeTotal;

    final blendedWave = ((calmShare * waveCalm) +
            (happy * 1.15 * waveBuoyant) +
            (excited * 1.35 * waveFast) +
            (supportive * 0.62 * waveSlow) +
            (concerned * 0.32 * waveSlow) +
            (curious * 0.85 * waveCurious)) /
        waveNorm;

    // Single-trigger celebratory bounce when entering excited.
    final b = animated ? bounce.value : 0.0;
    final bounceActive = (b > 0.0 && b < 1.0) ? 1.0 : 0.0;
    final bounceHop =
        bounceActive * math.sin(b * math.pi * 2.0) * (1.0 - b) * (1.0 - b);
    final bounceLift = bounceActive *
        math.sin(b * math.pi) *
        (1.0 - 0.35 * b) *
        (0.6 + 0.4 * excited.clamp(0.0, 1.0));

    // Posture: tilt, stance lift/settle, horizontal lean, and squash/stretch.
    final postureTilt = (happy * 0.088) -
        (excited * 0.105) -
        (supportive * 0.102) +
        (curious * 0.118) +
        swaySignal * (happy * 0.025 + excited * 0.04 + curious * 0.045);

    final postureDx = (curious * 3.8) -
        (supportive * 1.2) +
        swaySignal * (happy * 1.8 + excited * 2.6 + curious * 3.4);

    final postureDy = -(happy * 4.2) -
        (excited * 7.5) +
        (supportive * 4.2) +
        (concerned * 2.6) -
        (curious * 2.2) -
        (bounceLift * 11.0) +
        (bounceHop * 4.0);

    final floatAmplitude = 6.5 *
        ((calmShare * 1.0 +
                happy * 1.18 +
                excited * 1.35 +
                supportive * 0.65 +
                concerned * 0.32 +
                curious * 0.85) /
            waveNorm);
    final floatDy = -floatAmplitude * blendedWave;

    final stretchAmount = ((calmShare * 0.055 +
                happy * 0.068 +
                excited * 0.095 +
                supportive * 0.032 +
                concerned * 0.016 +
                curious * 0.048) /
            waveNorm) *
        blendedWave;

    final scaleX = 1.0 +
        (happy * 0.022) -
        (excited * 0.028) +
        (supportive * 0.032) +
        (concerned * 0.008) -
        (stretchAmount * 0.35) -
        (bounceLift * 0.045) +
        (bounceHop * 0.04);

    final scaleY = 1.0 +
        (happy * 0.012) +
        (excited * 0.045) -
        (supportive * 0.022) -
        (concerned * 0.014) +
        (curious * 0.015) +
        stretchAmount +
        (bounceLift * 0.065) -
        (bounceHop * 0.04);

    canvas.save();
    canvas.scale(size.width / 231.0);

    // Subtle ambient aura behind the ghost for warm/comforting states,
    // strictly inside the 231 x 311.85 logical canvas bounds.
    final auraStrength =
        (excited * 0.34 + happy * 0.18 + supportive * 0.20 + curious * 0.14)
            .clamp(0.0, 0.42);
    if (auraStrength > 0.01) {
      final auraColor = _blendMoodColor(
        AppColors.lavender,
        happyColor: AppColors.blush,
        excitedColor: AppColors.gold,
        supportiveColor: AppColors.blush,
        concernedColor: AppColors.coreCyan,
        curiousColor: AppColors.coreCyan,
        happy: happy,
        excited: excited,
        supportive: supportive,
        concerned: concerned,
        curious: curious,
      );
      final auraCenter = Offset(
        (115.4 + postureDx).clamp(95.0, 135.0),
        (152.0 + postureDy + floatDy * 0.5).clamp(125.0, 178.0),
      );
      canvas.drawOval(
        Rect.fromCenter(center: auraCenter, width: 216, height: 274),
        Paint()
          ..shader = RadialGradient(
            colors: [
              auraColor.withValues(alpha: auraStrength),
              auraColor.withValues(alpha: auraStrength * 0.35),
              auraColor.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.58, 1.0],
          ).createShader(Rect.fromCircle(center: auraCenter, radius: 138)),
      );
    }

    // Transform around a central body pivot with a 0.86 safety fit factor so
    // rotations, stretches, and bounces never clip at any animation extreme.
    const pivotX = 115.4045;
    const pivotY = 160.0;
    const baseFit = 0.86;
    canvas.translate(
      pivotX + postureDx.clamp(-6.5, 6.5),
      pivotY + 6.0 + (postureDy + floatDy).clamp(-15.5, 12.0),
    );
    canvas.rotate(postureTilt.clamp(-0.14, 0.14));
    canvas.scale(
      (baseFit * scaleX).clamp(0.78, 0.92),
      (baseFit * scaleY).clamp(0.78, 0.94),
    );
    canvas.translate(-pivotX, -152.0);

    const bounds = Rect.fromLTWH(0, 0, 231, 289);

    final c0 = _blendMoodColor(
      const Color(0xFFFFB3D9),
      happyColor: const Color(0xFFFFC9E3),
      excitedColor: const Color(0xFFFFE2F0),
      supportiveColor: const Color(0xFFF6C4DC),
      concernedColor: const Color(0xFFD2C4EB),
      curiousColor: const Color(0xFFE2CAFF),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final c1 = _blendMoodColor(
      const Color(0xFF87CEEB),
      happyColor: const Color(0xFFFFDFA8),
      excitedColor: const Color(0xFFFFE494),
      supportiveColor: const Color(0xFFD5B9F2),
      concernedColor: const Color(0xFF88C2E0),
      curiousColor: const Color(0xFFA2ECFF),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final c2 = _blendMoodColor(
      const Color(0xFF4A90E2),
      happyColor: const Color(0xFF67B4F5),
      excitedColor: const Color(0xFF75DCFF),
      supportiveColor: const Color(0xFF7E8CE0),
      concernedColor: const Color(0xFF3E77B6),
      curiousColor: const Color(0xFF5A9CF2),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final c3 = _blendMoodColor(
      const Color(0xFF2C3E50),
      happyColor: const Color(0xFF3A4C6B),
      excitedColor: const Color(0xFF4E4278),
      supportiveColor: const Color(0xFF3B3556),
      concernedColor: const Color(0xFF23364A),
      curiousColor: const Color(0xFF2F3D63),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final c4 = _blendMoodColor(
      const Color(0xFF1A1A2E),
      happyColor: const Color(0xFF222038),
      excitedColor: const Color(0xFF261E3C),
      supportiveColor: const Color(0xFF221D32),
      concernedColor: const Color(0xFF141B26),
      curiousColor: const Color(0xFF1B1E36),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );

    canvas.drawPath(
      _bodyPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c0, c1, c2, c3, c4],
        ).createShader(bounds),
    );

    canvas.save();
    canvas.clipPath(_bodyPath);

    final radial0 = _blendMoodColor(
      AppColors.blush,
      happyColor: const Color(0xFFFFC8DC),
      excitedColor: AppColors.gold,
      supportiveColor: AppColors.blush,
      concernedColor: AppColors.coreCyan,
      curiousColor: AppColors.coreCyan,
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final radial1 = _blendMoodColor(
      AppColors.coreCyan,
      happyColor: const Color(0xFFFFE3A3),
      excitedColor: AppColors.blush,
      supportiveColor: AppColors.lavender,
      concernedColor: AppColors.lavender,
      curiousColor: AppColors.coreViolet,
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );
    final radial2 = _blendMoodColor(
      AppColors.lavender,
      happyColor: AppColors.coreCyan,
      excitedColor: AppColors.coreViolet,
      supportiveColor: AppColors.coreViolet,
      concernedColor: const Color(0xFF6DA4D8),
      curiousColor: AppColors.blush,
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );

    final phaseShift =
        (happy * 0.35) + (excited * 0.7) - (supportive * 0.4) + (curious * 0.5);
    for (final (i, color) in [radial0, radial1, radial2].indexed) {
      final center = Offset(
        115 + 95 * math.sin(t * 0.65 + i * 2.1 + phaseShift),
        135 +
            115 * math.cos(t * 0.5 + i * 2.1 + phaseShift * 0.7) -
            (happy + excited) * 14 +
            supportive * 10,
      );
      canvas.drawCircle(
        center,
        155,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.82),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: 155)),
      );
    }

    // Warm inner crown/chest highlight for joyful or comforting states.
    final innerGlowAlpha =
        (excited * 0.38 + happy * 0.24 + supportive * 0.26).clamp(0.0, 0.42);
    if (innerGlowAlpha > 0.01) {
      final glowCenter = Offset(
        115.4,
        105.0 - (excited * 22.0) - (happy * 12.0) + (supportive * 38.0),
      );
      final glowColor = _blendMoodColor(
        AppColors.ivory,
        happyColor: const Color(0xFFFFF0C8),
        excitedColor: const Color(0xFFFFF4D2),
        supportiveColor: const Color(0xFFFFDCE8),
        concernedColor: AppColors.coreCyan,
        curiousColor: AppColors.coreCyan,
        happy: happy,
        excited: excited,
        supportive: supportive,
        concerned: concerned,
        curious: curious,
      );
      canvas.drawCircle(
        glowCenter,
        98,
        Paint()
          ..shader = RadialGradient(
            colors: [
              glowColor.withValues(alpha: innerGlowAlpha),
              glowColor.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: glowCenter, radius: 98)),
      );
    }

    canvas.restore();

    // Natural 3-second blink cycle (calmly open when animated == false).
    final blinkPhase = (t % 3) / 3;
    final rawBlink = blinkPhase > 0.9
        ? 1 - 0.9 * (1 - ((blinkPhase - 0.95) / 0.05).abs())
        : 1.0;
    final blink = rawBlink.clamp(0.1, 1.0);

    // Bounded additive pointer gaze + inquisitive searching glance when animated.
    final rawGaze = gaze();
    final searchDx = searchSignal * (curious * 3.2);
    final searchDy =
        (animated ? math.cos(t * 2 * math.pi / 4.2) : 0.0) * (curious * 1.5);
    final eyeColor = _blendMoodColor(
      AppColors.ivory,
      happyColor: const Color(0xFFFFF8EA),
      excitedColor: const Color(0xFFFFFAF0),
      supportiveColor: const Color(0xFFF9EAE8),
      concernedColor: const Color(0xFFEEEBF2),
      curiousColor: const Color(0xFFF6F2FA),
      happy: happy,
      excited: excited,
      supportive: supportive,
      concerned: concerned,
      curious: curious,
    );

    for (final side in [-1.0, 1.0]) {
      _paintEye(
        canvas: canvas,
        side: side,
        blink: blink,
        gaze: rawGaze + Offset(searchDx, searchDy),
        eyeColor: eyeColor,
        happy: happy,
        excited: excited,
        supportive: supportive,
        concerned: concerned,
        curious: curious,
      );
    }

    canvas.restore();
  }

  void _paintEye({
    required Canvas canvas,
    required double side,
    required double blink,
    required Offset gaze,
    required Color eyeColor,
    required double happy,
    required double excited,
    required double supportive,
    required double concerned,
    required double curious,
  }) {
    final isRight = side > 0;
    final baseX = isRight ? 150.0 : 80.0;
    const baseY = 120.0;

    // Emotional eye position offsets (curious is asymmetric; supportive draws
    // slightly closer and softer; excited lifts high).
    final moodDx = (excited * side * 1.8) -
        (supportive * side * 2.8) -
        (concerned * side * 1.0) +
        (curious * (isRight ? 5.2 : 4.2));
    final moodDy = -(happy * 3.2) -
        (excited * 6.5) +
        (supportive * 4.5) +
        (concerned * 2.2) +
        (curious * (isRight ? -6.5 : 4.2));

    // Keep combined emotional offset + pointer gaze strictly inside the head.
    final cx = (baseX + moodDx + gaze.dx).clamp(52.0, 179.0);
    final cy = (baseY + moodDy + gaze.dy).clamp(84.0, 154.0);

    final rx = (20.0 +
            (happy * 3.6) +
            (excited * 3.8) +
            (supportive * 1.6) +
            (concerned * 2.2) +
            (curious * (isRight ? 3.8 : -1.8)))
        .clamp(14.0, 26.0);

    final baseRy = (30.0 -
            (happy * 3.5) +
            (excited * 4.2) -
            (supportive * 3.8) -
            (concerned * 10.5) +
            (curious * (isRight ? 4.0 : -9.0)))
        .clamp(14.0, 36.0);
    final ry = math.max(2.6, baseRy * blink);

    final eyeTilt = -(happy * side * 0.06) -
        (excited * side * 0.08) +
        (supportive * side * 0.16) +
        (curious * 0.085);

    // Shape parameters in normalized eye coordinates:
    // topArch: 1.0 is standard oval top; lower values flatten the top lid.
    final topArch = (1.0 +
            (happy * 0.08) +
            (excited * 0.10) -
            (supportive * 0.08) -
            (concerned * 0.38) +
            (curious * (isRight ? 0.12 : -0.30)))
        .clamp(0.48, 1.22);

    // topOuterDrop: positive values slope the outer upper lid gently downward
    // (supportive empathy), negative values lift the outer lid (happy/excited).
    final topOuterDrop = (supportive * 0.48) -
        (happy * 0.10) -
        (excited * 0.12) -
        (curious * (isRight ? 0.12 : -0.05));

    // bottomSmileArch: 0.0 is standard oval bottom (+1.0 * ry);
    // approaching 1.0 arches the lower lid upward into a delighted crescent.
    final smileArch =
        (happy * 0.96 + excited * 0.22 + supportive * 0.14).clamp(0.0, 1.05);

    final cornerInY = ((happy * 0.24) -
            (supportive * 0.12) +
            (concerned * 0.04) +
            (curious * (isRight ? 0.0 : 0.05))) *
        ry;
    final cornerOutY = ((happy * 0.16) -
            (excited * 0.10) +
            (supportive * 0.26) +
            (concerned * 0.04) -
            (curious * (isRight ? 0.06 : 0.0))) *
        ry;

    final topPeakY = -topArch * ry;
    final topInCtrlY = topPeakY - (topOuterDrop * 0.28 * ry);
    final topOutCtrlY = topPeakY + (topOuterDrop * 0.85 * ry);

    // As smileArch rises from 0 to 1, bottomY lifts from +ry up to -0.22 * ry,
    // creating a warm upward crescent while keeping the side tips rounded.
    final bottomCenterY = (1.0 - 1.22 * smileArch) * ry;
    final sideUpperTan = (0.55 - 0.18 * concerned.clamp(0.0, 1.0)) * ry;
    final sideLowerTan = (0.55 - 0.28 * smileArch.clamp(0.0, 1.0)) * ry;

    final inX = -side * rx;
    final outX = side * rx;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(eyeTilt);

    var eyePath = Path()
      ..moveTo(inX, cornerInY)
      ..cubicTo(
        inX,
        cornerInY - sideUpperTan,
        -side * rx * 0.55,
        topInCtrlY,
        0,
        topPeakY,
      )
      ..cubicTo(
        side * rx * 0.55,
        topOutCtrlY,
        outX,
        cornerOutY - sideUpperTan * (1.0 - 0.35 * topOuterDrop.clamp(0.0, 1.0)),
        outX,
        cornerOutY,
      )
      ..cubicTo(
        outX,
        cornerOutY + sideLowerTan,
        side * rx * 0.52,
        bottomCenterY,
        0,
        bottomCenterY,
      )
      ..cubicTo(
        -side * rx * 0.52,
        bottomCenterY,
        inX,
        cornerInY + sideLowerTan,
        inX,
        cornerInY,
      )
      ..close();

    // Carve a 4-point star sparkle cutout inside the eye for excited state,
    // scaled smoothly by the excited blend weight so transitions are seamless.
    final starWeight = (excited * blink).clamp(0.0, 1.0);
    if (starWeight > 0.04 && smileArch < 0.75) {
      final starRx = 12.5 * starWeight;
      final starRy = 16.5 * starWeight;
      final waist = 3.6 * starWeight;
      final sx = (gaze.dx * 0.18).clamp(-3.0, 3.0);
      final sy = -2.0 + (gaze.dy * 0.18).clamp(-3.0, 3.0);
      final star = Path()
        ..moveTo(sx, sy - starRy)
        ..quadraticBezierTo(sx + waist, sy - waist, sx + starRx, sy)
        ..quadraticBezierTo(sx + waist, sy + waist, sx, sy + starRy)
        ..quadraticBezierTo(sx - waist, sy + waist, sx - starRx, sy)
        ..quadraticBezierTo(sx - waist, sy - waist, sx, sy - starRy)
        ..close();
      eyePath = Path.combine(PathOperation.difference, eyePath, star);
    }

    canvas.drawPath(eyePath, Paint()..color = eyeColor);

    // Subtle composed focus pupil/cutout for concerned/curious/supportive to
    // keep small sizes (18px/30px) and welcome size (132px) rich and readable.
    final focusStrength =
        (concerned * 0.85 + curious * (isRight ? 0.55 : 0.25))
            .clamp(0.0, 0.9) *
        blink;
    if (focusStrength > 0.08 && smileArch < 0.6) {
      final pupilCenter = Offset(
        (gaze.dx * 0.22 + (curious * 2.2)).clamp(-5.0, 5.0),
        (gaze.dy * 0.22 + (concerned * 1.5)).clamp(-4.0, 4.0),
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: pupilCenter,
          width: 11.5 * focusStrength,
          height: 14.0 * focusStrength,
        ),
        Paint()
          ..color = const Color(0xFF1F2438)
              .withValues(alpha: 0.42 * focusStrength),
      );
    }

    // Soft expressive brow contour above the eye that fades in smoothly for
    // active moods (0 alpha in calm) to reinforce sympathy, focus, or curiosity.
    final browAlpha = ((supportive * 0.78) +
            (concerned * 0.82) +
            (curious * (isRight ? 0.82 : 0.58)) +
            (happy * 0.38) +
            (excited * 0.48))
        .clamp(0.0, 0.85);
    if (browAlpha > 0.02) {
      final browY = topPeakY -
          8.5 -
          (excited * 4.0) -
          (happy * 2.5) -
          (curious * (isRight ? 5.0 : -1.5)) +
          (concerned * 2.0);
      final browInY = browY +
          (happy * 3.0) +
          (excited * 3.5) -
          (supportive * 4.5) +
          (curious * (isRight ? 3.5 : 0.5));
      final browOutY = browY +
          (happy * 3.5) +
          (excited * 2.5) +
          (supportive * 8.5) +
          (curious * (isRight ? 2.0 : 1.0));
      final browPeakY = browY -
          (happy * 4.5) -
          (excited * 5.5) -
          (supportive * 1.5) +
          (concerned * 0.5) -
          (curious * (isRight ? 5.5 : -0.5));

      final browPath = Path()
        ..moveTo(inX * 0.82, browInY)
        ..quadraticBezierTo(0, browPeakY, outX * 0.88, browOutY);
      canvas.drawPath(
        browPath,
        Paint()
          ..color = eyeColor.withValues(alpha: browAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.6
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.restore();
  }

  static Color _blendMoodColor(
    Color calmColor, {
    required Color happyColor,
    required Color excitedColor,
    required Color supportiveColor,
    required Color concernedColor,
    required Color curiousColor,
    required double happy,
    required double excited,
    required double supportive,
    required double concerned,
    required double curious,
  }) {
    final totalShift = happy + excited + supportive + concerned + curious;
    final baseWeight = math.max(0.0, 1.0 - totalShift);
    final norm = baseWeight + totalShift;
    final r = (calmColor.r * baseWeight +
            happyColor.r * happy +
            excitedColor.r * excited +
            supportiveColor.r * supportive +
            concernedColor.r * concerned +
            curiousColor.r * curious) /
        norm;
    final g = (calmColor.g * baseWeight +
            happyColor.g * happy +
            excitedColor.g * excited +
            supportiveColor.g * supportive +
            concernedColor.g * concerned +
            curiousColor.g * curious) /
        norm;
    final b = (calmColor.b * baseWeight +
            happyColor.b * happy +
            excitedColor.b * excited +
            supportiveColor.b * supportive +
            concernedColor.b * concerned +
            curiousColor.b * curious) /
        norm;
    return Color.from(
      alpha: 1.0,
      red: r.clamp(0.0, 1.0),
      green: g.clamp(0.0, 1.0),
      blue: b.clamp(0.0, 1.0),
    );
  }

  @override
  bool shouldRepaint(covariant _GhostPainter oldDelegate) => true;
}
