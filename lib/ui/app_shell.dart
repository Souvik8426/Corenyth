import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass_surface.dart';
import 'aurora_background.dart';
import 'user_avatar.dart';

/// Shared safe-area shell. IndexedStack keeps a conversation alive across tabs.
class AppShell extends StatefulWidget {
  final String profileName;
  final List<Widget> pages;
  final VoidCallback onProfile;
  final VoidCallback onSettings;
  final ValueChanged<int>? onDestinationChanged;
  final Widget? sidebar;
  final int? selectedDestination;
  const AppShell(
      {required this.pages,
      this.profileName = '',
      required this.onProfile,
      required this.onSettings,
      this.onDestinationChanged,
      this.sidebar,
      this.selectedDestination,
      super.key})
      : assert(pages.length == 3);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selected = 0;
  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedDestination != null) {
      _selected = widget.selectedDestination!;
    }
  }

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

  Widget _topBar(bool wide) {
    final logo = Image.asset('assets/branding/corenyth-logo-dark.png',
        width: 36, height: 44, excludeFromSemantics: true);
    final brand = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Corenyth', style: Theme.of(context).textTheme.titleMedium),
          Text('Your on-device space',
              style: Theme.of(context).textTheme.bodySmall),
        ]);
    final menu = Builder(
        builder: (context) => IconButton(
            tooltip: 'Chat history',
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu_rounded)));
    final settings = IconButton(
        tooltip: 'Model settings',
        onPressed: widget.onSettings,
        icon: const Icon(Icons.tune_rounded, size: 22));
    final profile = IconButton(
        tooltip: 'Your profile',
        onPressed: widget.onProfile,
        icon: UserAvatar(name: widget.profileName, size: 34));
    if (!wide &&
        MediaQuery.sizeOf(context).width < 450 &&
        MediaQuery.textScalerOf(context).scale(14) > 18) {
      return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              logo,
              const SizedBox(width: 10),
              Expanded(child: brand)
            ]),
            Row(children: [
              if (widget.sidebar != null) menu,
              const Spacer(),
              settings,
              profile
            ]),
          ]));
    }
    return Row(children: [
      if (!wide && widget.sidebar != null) menu,
      logo,
      const SizedBox(width: 10),
      Expanded(child: brand),
      settings,
      const SizedBox(width: 4),
      profile
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Stack(children: [
      const Positioned.fill(child: AuroraBackground()),
      Scaffold(
        backgroundColor: AppColors.transparent,
        drawer: !wide && widget.sidebar != null
            ? Drawer(
                backgroundColor: AppColors.transparent,
                width: 290,
                shape: const RoundedRectangleBorder(
                    borderRadius: AppTheme.drawerRadius),
                child: GlassSurface(
                    strong: true,
                    radius: AppTheme.drawerRadius,
                    child: SafeArea(child: widget.sidebar!)))
            : null,
        body: SafeArea(
            child: Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 8, wide ? 24 : 16, 12),
            child: GlassSurface(child: _topBar(wide)),
          ),
          Expanded(
              child: Row(children: [
            if (wide)
              if (widget.sidebar != null)
                SizedBox(width: 260, child: widget.sidebar!),
            if (wide)
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: NavigationRail(
                    backgroundColor: AppColors.surface,
                    selectedIndex: _selected,
                    onDestinationSelected: _select,
                    labelType: NavigationRailLabelType.all,
                    indicatorColor: AppColors.coreViolet,
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
              child: GlassSurface(
                radius: BorderRadius.circular(AppTheme.radiusXl),
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
                                    ? AppColors.selectedTile
                                    : AppColors.transparent,
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusLg),
                                child: InkWell(
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.radiusLg),
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
                                                    ? AppColors.coreViolet
                                                    : AppColors.tertiaryText),
                                            const SizedBox(height: 4),
                                            Text(_labels[i],
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelMedium!
                                                    .copyWith(
                                                        color: _selected == i
                                                            ? AppColors.ivory
                                                            : AppColors
                                                                .tertiaryText)),
                                          ])),
                                ),
                              )),
                        )),
                    ])),
              ),
            ),
        ])),
      ),
    ]);
  }
}
