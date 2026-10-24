import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// One bounded backdrop pass, reserved for floating chrome. The highlight is
/// painted over the fill, so it does not require another compositing layer.
class GlassSurface extends StatelessWidget {
  const GlassSurface(
      {super.key,
      required this.child,
      this.strong = false,
      this.radius = const BorderRadius.all(Radius.circular(AppTheme.radiusLg)),
      this.blur = true});
  final Widget child;
  final bool strong;
  final BorderRadius radius;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: strong
            ? AppColors.glassStrong
            : blur
                ? AppColors.glassFill
                : AppColors.selectedTile,
        borderRadius: radius,
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: CustomPaint(
        foregroundPainter: _TopHighlight(radius),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: const [
        BoxShadow(
            color: AppColors.glassShadow,
            blurRadius: 30,
            offset: Offset(0, 10)),
      ]),
      child: ClipRRect(
          borderRadius: radius,
          child: blur
              ? BackdropFilter(
                  filter: ui.ImageFilter.compose(
                      outer: ui.ColorFilter.matrix(_saturation),
                      inner: ui.ImageFilter.blur(
                          sigmaX: strong
                              ? AppTheme.overlayBlur
                              : AppTheme.glassBlur,
                          sigmaY: strong
                              ? AppTheme.overlayBlur
                              : AppTheme.glassBlur)),
                  child: content)
              : content),
    );
  }

  // CSS saturate(140%), using the luminance weights of the CSS filter.
  static const _s = AppTheme.glassSaturation;
  static const _r = .213 * (1 - _s);
  static const _g = .715 * (1 - _s);
  static const _b = .072 * (1 - _s);
  static const _saturation = <double>[
    _r + _s,
    _g,
    _b,
    0,
    0,
    _r,
    _g + _s,
    _b,
    0,
    0,
    _r,
    _g,
    _b + _s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];
}

class _TopHighlight extends CustomPainter {
  const _TopHighlight(this.radius);
  final BorderRadius radius;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(radius.toRRect(Offset.zero & size));
    canvas.drawLine(
        const Offset(0, .5),
        Offset(size.width, .5),
        Paint()
          ..color = AppColors.glassHighlight
          ..strokeWidth = 1);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TopHighlight oldDelegate) => radius != oldDelegate.radius;
}

/// Includes its own handle so the entire sheet shares one backdrop layer.
class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => GlassSurface(
      strong: true,
      radius: AppTheme.sheetRadius,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 16),
            child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.glassBorder,
                    borderRadius: BorderRadius.circular(AppTheme.radiusXs)))),
        Flexible(child: child),
      ]));
}
