import 'package:flutter/material.dart';

import '../services/model_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass_surface.dart';

class ModelStatusView extends StatelessWidget {
  final ModelState? modelState;
  final ModelLoad load;
  final VoidCallback onTap;

  /// Catalog label the user chose (may differ from [activeLabel] after fallback).
  final String? selectedLabel;

  /// Catalog label actually loaded, or null when on rules.
  final String? activeLabel;

  /// True when active model is not the selected one (or rules after failed load).
  final bool fellBack;
  final String? lastAnswerSource;

  const ModelStatusView(
      {required this.modelState,
      required this.load,
      required this.onTap,
      this.selectedLabel,
      this.activeLabel,
      this.fellBack = false,
      this.lastAnswerSource,
      super.key});

  @override
  Widget build(BuildContext context) {
    final label = switch (load) {
      ModelLoad.loading => 'Loading local model…',
      ModelLoad.loaded =>
        activeLabel != null ? 'Loaded · $activeLabel' : 'Local model loaded',
      ModelLoad.failed => fellBack && activeLabel != null
          ? 'Using $activeLabel · selected failed'
          : 'Model unavailable · Built-in rules',
      ModelLoad.idle => switch (modelState) {
          null => 'Checking local model…',
          ModelState.ready => selectedLabel != null
              ? 'Ready · $selectedLabel'
              : 'Local model available',
          _ => 'Built-in rules · On device',
        },
    };
    final detail = fellBack && load == ModelLoad.loaded
        ? 'Fell back from selected model. RAM/latency not measured on this device.'
        : (load == ModelLoad.loaded || modelState == ModelState.ready)
            ? 'RAM and latency not measured on this device.'
            : null;
    final indicator = SizedBox(
        width: 16,
        height: 16,
        child: Center(
            child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: load == ModelLoad.loaded
                        ? AppColors.success
                        : AppColors.tertiaryText))));
    final copy = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.ivory)),
          if (lastAnswerSource != null)
            Text('Last answer: $lastAnswerSource',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(height: 14 / 12)),
          if (detail != null)
            Text(detail,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: AppColors.tertiaryText, height: 14 / 12)),
        ]);
    final action = TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        child: Text(modelState == ModelState.ready ? 'Details' : 'Set up'));
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GlassSurface(
            radius: BorderRadius.circular(AppTheme.radiusMd),
            child: Padding(
                padding: const EdgeInsets.only(
                    left: 15, right: 5, top: 5, bottom: 5),
                child: LayoutBuilder(builder: (context, bounds) {
                  if (bounds.maxWidth < 450 &&
                      MediaQuery.textScalerOf(context).scale(14) > 18) {
                    return Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        indicator,
                        const SizedBox(width: 8),
                        Expanded(child: copy)
                      ]),
                      Align(alignment: Alignment.centerRight, child: action),
                    ]);
                  }
                  return Row(children: [
                    indicator,
                    const SizedBox(width: 8),
                    Expanded(child: copy),
                    action
                  ]);
                }))));
  }
}
