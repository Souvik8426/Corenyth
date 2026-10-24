import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass_surface.dart';

/// Keeps the AlertDialog API/semantics while bounding the filter to its panel.
class GlassAlertDialog extends AlertDialog {
  const GlassAlertDialog(
      {super.key,
      super.title,
      super.content,
      super.actions,
      super.icon,
      super.backgroundColor,
      super.insetPadding,
      super.titleTextStyle,
      super.scrollable,
      super.alignment});
  @override
  Widget build(BuildContext context) => Dialog(
      backgroundColor: AppColors.transparent,
      elevation: 0,
      insetPadding: insetPadding ??
          const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      alignment: alignment,
      child: GlassSurface(
          strong: true,
          radius: BorderRadius.circular(AppTheme.radiusXl),
          child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              label: semanticLabel ??
                  MaterialLocalizations.of(context).alertDialogLabel,
              explicitChildNodes: true,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 24, 22, 12),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (icon != null) ...[
                              icon!,
                              const SizedBox(height: 14)
                            ],
                            if (title != null) ...[
                              DefaultTextStyle(
                                  style: titleTextStyle ??
                                      Theme.of(context).textTheme.titleLarge!,
                                  child: title!),
                              const SizedBox(height: 8)
                            ],
                            if (content != null)
                              DefaultTextStyle(
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium!
                                      .copyWith(color: AppColors.muted),
                                  child: content!),
                            if (actions != null) ...[
                              const SizedBox(height: 16),
                              Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                      spacing: 8,
                                      alignment: WrapAlignment.end,
                                      children: actions!))
                            ],
                          ]))))));
}

class GlassSimpleDialog extends SimpleDialog {
  const GlassSimpleDialog({super.key, super.title, super.children});
  @override
  Widget build(BuildContext context) => GlassAlertDialog(
      title: title,
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children ?? const []));
}
