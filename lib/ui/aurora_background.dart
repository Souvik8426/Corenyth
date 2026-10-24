import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Static gradients, isolated from conversation/mascot animation repaints.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key});
  @override
  Widget build(BuildContext context) => const RepaintBoundary(
      child: CustomPaint(painter: _AuroraPainter(), size: Size.infinite));
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = AppColors.background);
    void glow(Offset center, double radius, Color color, double opacity) {
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..shader = RadialGradient(
              colors: [
                color.withValues(alpha: opacity),
                color.withValues(alpha: 0)
              ],
              stops: const [0, 1],
            ).createShader(Rect.fromCircle(center: center, radius: radius)));
    }

    glow(Offset(size.width * .11, size.height * .06), size.width * .85,
        AppColors.auroraViolet, .18);
    glow(Offset(size.width * 1.05, size.height * .39), size.width * .7,
        AppColors.auroraSky, .08);
    glow(Offset(size.width * .22, size.height * .75), size.width * .85,
        AppColors.auroraBlue, .12);
    glow(Offset(size.width, size.height), size.width * .7,
        AppColors.auroraIndigo, .14);
    canvas.save();
    canvas.translate(size.width * .5, size.height * .48);
    canvas.rotate(-.384);
    canvas.scale(1, .22);
    glow(Offset.zero, size.width, AppColors.coreViolet, .055);
    canvas.restore();
    canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: [
              AppColors.background.withValues(alpha: .45),
              AppColors.transparent
            ],
          ).createShader(bounds));
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) => false;
}
