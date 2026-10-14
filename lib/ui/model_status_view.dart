import 'package:flutter/material.dart';

import '../services/model_status.dart';
import '../theme/app_colors.dart';

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

  const ModelStatusView(
      {required this.modelState,
      required this.load,
      required this.onTap,
      this.selectedLabel,
      this.activeLabel,
      this.fellBack = false,
      super.key});

  @override
  Widget build(BuildContext context) {
    final label = switch (load) {
      ModelLoad.loading => 'Loading local model…',
      ModelLoad.loaded => activeLabel != null
          ? 'Using $activeLabel'
          : 'Local model loaded',
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
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.only(left: 14, right: 4, top: 4, bottom: 4),
          decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: AppColors.lavender.withValues(alpha: 0.10))),
          child: Row(children: [
            Icon(Icons.offline_bolt_outlined,
                size: 16,
                color: load == ModelLoad.loaded
                    ? AppColors.lavender
                    : AppColors.gold),
            const SizedBox(width: 8),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  Text(label, style: Theme.of(context).textTheme.bodySmall),
                  if (detail != null)
                    Text(detail,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.gold.withValues(alpha: 0.85))),
                ])),
            TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: Text(
                    modelState == ModelState.ready ? 'Details' : 'Set up')),
          ]),
        ));
  }
}
