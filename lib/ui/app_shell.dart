import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Shared safe-area shell. IndexedStack keeps a conversation alive across tabs.
class AppShell extends StatefulWidget {
  final List<Widget> pages;
  final VoidCallback onProfile;
  final VoidCallback onSettings;
  final ValueChanged<int>? onDestinationChanged;
  const AppShell(
      {required this.pages,
      required this.onProfile,
      required this.onSettings,
      this.onDestinationChanged,
      super.key})
      : assert(pages.length == 3);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selected = 0;
  static const _labels = ['Chat', 'Tasks', 'Memories'];
  static const _icons = [
    Icons.chat_bubble_outline_rounded,
    Icons.check_circle_outline_rounded,
    Icons.auto_awesome_outlined
  ];

  void _select(int index) {
    if (index == _selected) return;
    setState(() => _selected = index);
    widget.onDestinationChanged?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: SafeArea(
          child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 8, wide ? 24 : 16, 12),
          child: Row(children: [
            Image.asset('branding/corenyth-logo.png',
                width: 36, height: 36, excludeFromSemantics: true),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Corenyth',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('Your on-device space',
                      style: Theme.of(context).textTheme.bodySmall),
                ])),
            IconButton(
                tooltip: 'Model settings',
                onPressed: widget.onSettings,
                icon: const Icon(Icons.tune_rounded, size: 22)),
            const SizedBox(width: 4),
            IconButton.filledTonal(
                tooltip: 'Your profile',
                onPressed: widget.onProfile,
                style: IconButton.styleFrom(
                    backgroundColor: AppColors.surfaceRaised,
                    foregroundColor: AppColors.lavender,
                    minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.person_outline_rounded, size: 22)),
          ]),
        ),
        Expanded(
            child: Row(children: [
          if (wide)
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: NavigationRail(
                  backgroundColor: AppColors.surface,
                  selectedIndex: _selected,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  indicatorColor: AppColors.lavender,
                  selectedIconTheme:
                      const IconThemeData(color: AppColors.surface),
                  unselectedIconTheme:
                      const IconThemeData(color: AppColors.muted),
                  destinations: [
                    for (var i = 0; i < 3; i++)
                      NavigationRailDestination(
                          icon: Icon(_icons[i]), label: Text(_labels[i]))
                  ],
                )),
          Expanded(
              child: Center(
                  child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: IndexedStack(
                index: _selected,
                sizing: StackFit.expand,
                children: widget.pages),
          ))),
        ])),
        if (!wide && !keyboard)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                      color: AppColors.lavender.withValues(alpha: 0.12))),
              child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(children: [
                    for (var i = 0; i < 3; i++)
                      Expanded(
                          child: Semantics(
                        selected: _selected == i,
                        button: true,
                        child: Tooltip(
                            message: _labels[i],
                            child: Material(
                              color: _selected == i
                                  ? AppColors.lavender
                                  : AppColors.transparent,
                              borderRadius: BorderRadius.circular(999),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: () => _select(i),
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10, horizontal: 4),
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(_icons[i],
                                              size: 21,
                                              color: _selected == i
                                                  ? AppColors.surface
                                                  : AppColors.muted),
                                          const SizedBox(height: 4),
                                          Text(_labels[i],
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium!
                                                  .copyWith(
                                                      color: _selected == i
                                                          ? AppColors.surface
                                                          : AppColors.muted)),
                                        ])),
                              ),
                            )),
                      )),
                  ])),
            ),
          ),
      ])),
    );
  }
}
