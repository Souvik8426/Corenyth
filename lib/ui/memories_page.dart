import 'package:flutter/material.dart';

import '../data/repos.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'glass_surface.dart';
import 'glass_dialog.dart';
import 'user_avatar.dart';

/// Returns true only after a profile write has been verified by a fresh read.
Future<bool> showProfileEditor(
        BuildContext context, ProfileRepo profile) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      builder: (_) => _ProfileEditor(profile: profile),
    ) ??
    false;

class MemoriesPage extends StatefulWidget {
  const MemoriesPage({
    required this.memory,
    required this.profile,
    this.refreshToken = 0,
    super.key,
  });

  final MemoryRepo memory;
  final ProfileRepo profile;
  final int refreshToken;

  @override
  State<MemoriesPage> createState() => _MemoriesPageState();
}

class _MemoriesPageState extends State<MemoriesPage> {
  List<Memory> _memories = [];
  UserProfile? _profile;
  bool _loading = true;
  String? _loadError;
  int? _deleting;
  String? _actionError;
  final _search = TextEditingController();
  String? _category;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MemoriesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken ||
        oldWidget.memory != widget.memory ||
        oldWidget.profile != widget.profile) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _actionError = null;
    });
    try {
      final memories = await widget.memory.all();
      final profile = await widget.profile.get();
      if (!mounted) return;
      setState(() {
        _memories = memories;
        _profile = profile;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load context';
      });
    }
  }

  Future<void> _editProfile() async {
    final saved = await showProfileEditor(context, widget.profile);
    if (!mounted || !saved) return;
    await _load();
  }

  Future<void> _deleteMemory(Memory memory) async {
    final repo = widget.memory;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        scrollable: true,
        title: const Text('Delete this memory?'),
        content: Text(
            'This removes the saved memory from this device.\n\n${memory.content}'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep memory'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _deleting != null) return;
    setState(() {
      _deleting = memory.id;
      _actionError = null;
    });
    var deleted = false;
    try {
      if (!await repo.delete(memory.id))
        throw StateError('Memory was not deleted');
      deleted = true;
      final rows = await repo.all();
      if (rows.any((m) => m.id == memory.id))
        throw StateError('Delete readback failed');
      if (!mounted) return;
      setState(() {
        _memories = rows;
        _deleting = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deleting = null;
        _actionError = deleted
            ? 'Could not confirm deletion. Refresh to check saved data.'
            : 'Memory could not be deleted. Please try again.';
      });
    }
  }

  Future<void> _addMemory() async {
    final rows = await showModalBottomSheet<List<Memory>>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      builder: (_) => _AddMemorySheet(memory: widget.memory),
    );
    if (!mounted || rows == null) return;
    setState(() {
      _memories = rows;
      _search.clear();
      _category = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final query = _search.text.trim().toLowerCase();
    final categories = _memories.map((m) => m.category).toSet().toList()
      ..sort();
    final visible = _memories
        .where((m) =>
            (_category == null || m.category == _category) &&
            (m.content.toLowerCase().contains(query) ||
                m.category.toLowerCase().contains(query)))
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Context & memory', style: text.displayMedium),
          const SizedBox(height: 8),
          const Text('A little context for replies that feel more like you.',
              style: TextStyle(
                  color: AppColors.muted, fontSize: 13, height: 1.45)),
          const SizedBox(height: 16),
          Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _Badge('On this device'),
                IconButton(
                  tooltip: 'Refresh context',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: _loading || _deleting != null ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ]),
          const SizedBox(height: 14),
          if (_loading)
            const Center(
                child: CircularProgressIndicator(
                    semanticsLabel: 'Loading context'))
          else if (_loadError != null)
            _Surface(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_loadError!, style: text.titleMedium),
                const SizedBox(height: 8),
                const Text(
                    'Your saved data could not be read. Please try again.'),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: _load, child: const Text('Retry')),
              ],
            ))
          else ...[
            _Surface(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    UserAvatar(name: _profile?.name ?? ''),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('Your profile', style: text.bodySmall),
                          Text(_profile?.name ?? 'No profile yet',
                              style: text.titleSmall),
                          if (_profile?.occupation.isNotEmpty ?? false)
                            Text(_profile!.occupation, style: text.bodySmall),
                          Wrap(spacing: 6, children: [
                            Text('Assistant tone', style: text.bodySmall),
                            Text(
                                _profile == null
                                    ? 'Not set'
                                    : _title(_profile!.tone),
                                style: text.bodySmall
                                    ?.copyWith(color: AppColors.coreViolet)),
                          ]),
                        ])),
                  ]),
                  Wrap(spacing: 8, children: [
                    TextButton.icon(
                        onPressed: _deleting == null ? _editProfile : null,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit profile')),
                    TextButton(
                        onPressed: _deleting == null ? _editProfile : null,
                        child: const Text('Edit tone')),
                  ]),
                ])),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('Learned memories', style: text.titleSmall),
                    Text(
                        '${_memories.length} saved ${_memories.length == 1 ? 'memory' : 'memories'}',
                        style: text.bodySmall),
                  ])),
              OutlinedButton.icon(
                  onPressed: _deleting == null ? _addMemory : null,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Add memory')),
            ]),
            const SizedBox(height: 8),
            const Text(
                'Personal memories can shape replies. Other saved memories remain searchable.',
                style: TextStyle(
                    color: AppColors.muted, fontSize: 13, height: 1.45)),
            const SizedBox(height: 16),
            TextField(
              key: const Key('memory-search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Search memories',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _category == null,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => setState(() => _category = null),
              ),
              for (final category in categories)
                ChoiceChip(
                  label: Text(_title(category)),
                  selected: _category == category,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: (_) => setState(() => _category = category),
                ),
            ]),
            const SizedBox(height: 16),
            if (_actionError != null) ...[
              Semantics(
                  liveRegion: true,
                  child: Text(_actionError!,
                      style: const TextStyle(color: AppColors.error))),
              const SizedBox(height: 16),
            ],
            if (visible.isEmpty)
              _Surface(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      _memories.isEmpty
                          ? 'No memories yet'
                          : 'No matching memories',
                      style: text.titleMedium),
                  const SizedBox(height: 8),
                  Text(_memories.isEmpty
                      ? 'Save something you want to keep, or return after a conversation closes.'
                      : 'Try another search or category.'),
                  if (query.isNotEmpty || _category != null)
                    TextButton(
                        onPressed: () => setState(() {
                              _search.clear();
                              _category = null;
                            }),
                        child: const Text('Clear filters')),
                ],
              )),
            for (final memory in visible) ...[
              _Surface(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _Badge(memory.category),
                        IconButton(
                          key: Key('delete-memory-${memory.id}'),
                          tooltip: 'Delete memory: ${memory.content}',
                          constraints:
                              const BoxConstraints(minWidth: 48, minHeight: 48),
                          onPressed: _deleting == null
                              ? () => _deleteMemory(memory)
                              : null,
                          icon: Icon(_deleting == memory.id
                              ? Icons.hourglass_top_rounded
                              : Icons.delete_outline_rounded),
                        ),
                      ]),
                  const SizedBox(height: 16),
                  Text(memory.content, style: text.bodyLarge),
                ],
              )),
              const SizedBox(height: 16),
            ],
          ],
          const SizedBox(height: 8),
          const Text(
              'Personal facts and explicit “remember” requests are saved on this device during the conversation. Refresh to see newly saved context. Mem0 is not connected in this version.',
              style: TextStyle(
                  color: AppColors.muted, fontSize: 13, height: 1.45)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.profile});
  final ProfileRepo profile;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  static const _tones = [
    'cheerful',
    'mature',
    'playful',
    'calm',
    'professional'
  ];
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _occupation = TextEditingController();
  String _tone = 'cheerful';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _occupation.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.profile.get();
      if (!mounted) return;
      _name.text = value?.name ?? '';
      _occupation.text = value?.occupation ?? '';
      setState(() {
        _tone = value?.tone ?? 'cheerful';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load profile';
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final value = UserProfile(
        name: _name.text.trim(),
        occupation: _occupation.text.trim(),
        tone: _tone);
    setState(() {
      _saving = true;
      _error = null;
    });
    var wrote = false;
    try {
      await widget.profile.save(value);
      wrote = true;
      final saved = await widget.profile.get();
      if (saved == null ||
          saved.name != value.name ||
          saved.occupation != value.occupation ||
          saved.tone != value.tone) {
        throw StateError('Profile readback failed');
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = wrote
            ? 'Could not confirm saved profile. Please try again.'
            : 'Profile was not saved. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: _SheetBody(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Edit your profile',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
                'Choose how you introduce yourself and how the assistant replies.'),
            const SizedBox(height: 16),
            if (_loading)
              const CircularProgressIndicator(semanticsLabel: 'Loading profile')
            else if (_error == 'Could not load profile') ...[
              Semantics(
                  liveRegion: true,
                  child: Text(_error!,
                      style: const TextStyle(color: AppColors.error))),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ] else
              Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      key: const Key('profile-name'),
                      controller: _name,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (value) => (value?.trim().isEmpty ?? true)
                          ? 'Enter your name'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('profile-occupation'),
                      controller: _occupation,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                          labelText: 'Occupation (optional)'),
                    ),
                    const SizedBox(height: 16),
                    Text('Assistant tone',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final tone in _tones)
                        ChoiceChip(
                          label: Text(_title(tone)),
                          selected: _tone == tone,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() => _tone = tone),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    if (_error != null) ...[
                      Semantics(
                          liveRegion: true,
                          child: Text(_error!,
                              style: const TextStyle(color: AppColors.error))),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(children: [
              if (!_loading && _error != 'Could not load profile') ...[
                Expanded(
                    child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? 'Saving…' : 'Save profile'))),
                const SizedBox(width: 10),
              ],
              OutlinedButton(
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
            ]),
          ],
        )),
      );
}

class _AddMemorySheet extends StatefulWidget {
  const _AddMemorySheet({required this.memory});
  final MemoryRepo memory;

  @override
  State<_AddMemorySheet> createState() => _AddMemorySheetState();
}

class _AddMemorySheetState extends State<_AddMemorySheet> {
  final _form = GlobalKey<FormState>();
  final _content = TextEditingController();
  final _category = TextEditingController(text: 'fact');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    _category.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    var wrote = false;
    try {
      final id = await widget.memory
          .add(_content.text.trim(), category: _category.text.trim());
      wrote = true;
      final rows = await widget.memory.all();
      if (!rows.any((m) => m.id == id))
        throw StateError('Memory readback failed');
      if (!mounted) return;
      Navigator.of(context).pop(rows);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = wrote
            ? 'Could not confirm saved memory. Refresh before adding it again.'
            : 'Memory was not saved. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: _SheetBody(
            child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Save a memory',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Keep something worth remembering on this device.'),
              const SizedBox(height: 24),
              TextFormField(
                key: const Key('memory-content'),
                controller: _content,
                enabled: !_saving,
                minLines: 3,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Memory', alignLabelWithHint: true),
                validator: (value) =>
                    (value?.trim().isEmpty ?? true) ? 'Enter a memory' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('memory-category'),
                controller: _category,
                enabled: !_saving,
                decoration: const InputDecoration(
                    labelText: 'Category',
                    helperText: 'For example: fact, preference, or goal'),
                validator: (value) =>
                    (value?.trim().isEmpty ?? true) ? 'Enter a category' : null,
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Semantics(
                    liveRegion: true,
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.error))),
                const SizedBox(height: 16),
              ],
              Wrap(spacing: 16, runSpacing: 8, children: [
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style:
                      FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(_saving ? 'Saving…' : 'Save memory'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: const Text('Cancel'),
                ),
              ]),
            ],
          ),
        )),
      );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassSheet(
          child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              18, 0, 18, 26 + MediaQuery.viewInsetsOf(context).bottom),
          child: child,
        ),
      ));
}

String _title(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: child,
      );
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: AppColors.success)),
      );
}
