import 'package:flutter/material.dart';

import '../services/model_status.dart';
import '../theme/app_colors.dart';

class ModelStatusView extends StatelessWidget {
  final ModelState? modelState;
  final ModelLoad load;
  final VoidCallback onTap;
  const ModelStatusView(
      {required this.modelState,
      required this.load,
      required this.onTap,
      super.key});

  @override
  Widget build(BuildContext context) {
    final label = switch (load) {
      ModelLoad.loading => 'Loading local model…',
      ModelLoad.loaded => 'Local model loaded',
      ModelLoad.failed => 'Model unavailable · Built-in rules',
      ModelLoad.idle => switch (modelState) {
          null => 'Checking local model…',
          ModelState.ready => 'Local model available',
          _ => 'Built-in rules · On device',
        },
    };
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.only(left: 14, right: 4),
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
                child:
                    Text(label, style: Theme.of(context).textTheme.bodySmall)),
            TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                child: Text(
                    modelState == ModelState.ready ? 'Details' : 'Set up')),
          ]),
        ));
  }
}
