import 'package:flutter/material.dart';

/// A fixed arc rotates at constant speed: no stretching, breathing or jumps.
/// Its arc length is decorative, never a claim of measured load progress.
class ModelLoadingIndicator extends StatefulWidget {
  const ModelLoadingIndicator({super.key});
  @override
  State<ModelLoadingIndicator> createState() => _ModelLoadingIndicatorState();
}

class _ModelLoadingIndicatorState extends State<ModelLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _rotation.stop();
      _rotation.value = 0;
    } else {
      _rotation.repeat();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arc = CircularProgressIndicator(
      value: 0.75,
      strokeWidth: 3,
      strokeCap: StrokeCap.round,
      backgroundColor:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
    );
    return Semantics(
      label: 'Loading local model',
      liveRegion: true,
      child: ExcludeSemantics(
        child: Center(
          heightFactor: 1,
          child: SizedBox.square(
            dimension: 40,
            child: RotationTransition(turns: _rotation, child: arc),
          ),
        ),
      ),
    );
  }
}
