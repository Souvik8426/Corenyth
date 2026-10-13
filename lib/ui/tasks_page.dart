import 'package:flutter/material.dart';

import '../data/repos.dart';
import '../services/native_bridge.dart';
import '../theme/app_colors.dart';

class TasksPage extends StatefulWidget {
  const TasksPage(this.tasks, {super.key, this.refreshToken = 0});

  final TaskRepo tasks;
  final int refreshToken;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  List<Task> _tasks = [];
  bool _completed = false;
  bool _loading = true;
  bool _hasLoaded = false;
  String? _loadError;
  int _loadGeneration = 0;
  bool _mutating = false;
  String? _mutationError;
  Future<void> Function()? _retryMutation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tasks != widget.tasks ||
        oldWidget.refreshToken != widget.refreshToken) {
      if (oldWidget.tasks != widget.tasks) {
        _tasks = [];
        _hasLoaded = false;
      }
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() { _loading = true; _loadError = null; });
    try {
      final tasks = await widget.tasks.list(includeDone: true);
      if (!mounted || generation != _loadGeneration) return;
      setState(() { _tasks = tasks; _hasLoaded = true; });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadError = 'Couldn’t load tasks.');
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggle(Task task) => _mutate(() => task.done
      ? widget.tasks.update(task.id, {'status': 'pending', 'completed_at': null})
      : widget.tasks.complete(task.id));

  Future<void> _mutate(Future<bool> Function() write) async {
    if (_mutating) return;
    setState(() { _mutating = true; _mutationError = null; _retryMutation = null; });
    try {
      final changed = await write();
      if (!changed) throw StateError('Task no longer exists');
      await NativeBridge.refreshWidget();
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() {
        _mutationError = 'Couldn’t update task. Try again.';
        _retryMutation = () => _mutate(write);
      });
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _confirmDelete(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('“${task.title}” will be permanently deleted.'),
        scrollable: true,
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48),
              backgroundColor: AppColors.error, foregroundColor: AppColors.surface),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _mutate(() => widget.tasks.delete(task.id));
    }
  }

  Future<void> _openEditor([Task? task]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: AppColors.surfaceRaised,
      builder: (context) => _TaskEditor(task: task, onSave: (title, notes, due, priority) async {
        if (task == null) {
          await widget.tasks.create(title, notes: notes, due: due, priority: priority);
        } else {
          final changed = await widget.tasks.update(task.id, {
            'title': title, 'notes': notes,
            'due_at': due?.millisecondsSinceEpoch, 'priority': priority,
          });
          if (!changed) throw StateError('Task no longer exists');
        }
        await NativeBridge.refreshWidget();
        if (mounted) {
          if (task == null) setState(() => _completed = false);
          await _load();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _tasks.where((task) => !task.done).length;
    final done = _tasks.length - pending;
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: AppColors.background,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text('Tasks', style: text.displaySmall)),
            IconButton(
              tooltip: 'Refresh tasks',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ]),
          const SizedBox(height: 8),
          Text(_hasLoaded ? '$pending ${pending == 1 ? 'task' : 'tasks'} pending'
              : 'A little space for what’s next.',
              style: text.bodyMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 16),
          Align(alignment: Alignment.centerLeft, child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _mutating ? null : _openEditor,
            icon: const Icon(Icons.add_rounded), label: const Text('Add task'))),
          const SizedBox(height: 24),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _filter('Active ($pending)', false),
            _filter('Completed ($done)', true),
          ]),
          const SizedBox(height: 24),
          if (_loading) ...[
            const Center(child: SizedBox(width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))),
            const SizedBox(height: 16),
            const Center(child: Text('Loading tasks…')),
            const SizedBox(height: 24),
          ],
          if (_mutationError != null) ...[
            Text(_mutationError!, style: text.bodyMedium?.copyWith(color: AppColors.error)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _mutating ? null : _retryMutation,
              child: const Text('Retry action'))),
            const SizedBox(height: 16),
          ],
          if (_loadError != null) ...[
            Text(_loadError!, style: text.bodyMedium?.copyWith(color: AppColors.error)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _load, child: const Text('Retry'))),
            const SizedBox(height: 16),
          ],
          if (!_loading && _loadError == null &&
              _tasks.where((task) => task.done == _completed).isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: AppColors.surface,
                  borderRadius: BorderRadius.circular(24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_completed ? 'No completed tasks' : 'No active tasks',
                    style: text.titleMedium),
                const SizedBox(height: 8),
                Text(_completed ? 'Finished tasks will live here.'
                    : 'Take a breath. Add something when you’re ready.',
                    style: text.bodyMedium?.copyWith(color: AppColors.muted)),
              ]),
            ),
          for (final task in _tasks.where((task) => task.done == _completed))
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _card(task),
            ),
        ],
        ),
      ),
    );
  }

  Widget _filter(String label, bool completed) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      backgroundColor: _completed == completed
          ? AppColors.lavender.withValues(alpha: 0.18)
          : AppColors.surface,
      side: BorderSide(color: _completed == completed
          ? AppColors.lavender : AppColors.muted.withValues(alpha: 0.4)),
    ),
    onPressed: () => setState(() => _completed = completed),
    child: Text(label),
  );

  Widget _card(Task task) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.lavender.withValues(alpha: 0.12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(
            tooltip: task.done ? 'Restore task' : 'Complete task',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            color: task.done ? AppColors.success : AppColors.lavender,
            onPressed: _mutating ? null : () => _toggle(task),
            icon: Icon(task.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked),
          ),
          const SizedBox(width: 8),
          Expanded(child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(task.title, style: text.titleMedium?.copyWith(
              decoration: task.done ? TextDecoration.lineThrough : null,
              color: task.done ? AppColors.muted : AppColors.ivory,
            )),
          )),
        ]),
        if (task.notes?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(task.notes!, style: text.bodyMedium?.copyWith(color: AppColors.muted)),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 8, children: [
          Text('${_priority(task.priority)} priority', style: text.bodySmall?.copyWith(
            color: task.priority == 2 ? AppColors.gold : AppColors.muted)),
          Text(task.dueAt == null ? 'No due date' : _dueLabel(context, task.dueAt!),
              style: text.bodySmall),
        ]),
        const SizedBox(height: 16),
        Align(alignment: Alignment.centerRight, child: Wrap(spacing: 8, children: [
          IconButton(
            tooltip: 'Edit task',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _mutating ? null : () => _openEditor(task),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete task',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            color: AppColors.muted,
            onPressed: _mutating ? null : () => _confirmDelete(task),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ])),
      ]),
    );
  }
}

class _TaskEditor extends StatefulWidget {
  const _TaskEditor({this.task, required this.onSave});
  final Task? task;
  final Future<void> Function(String title, String? notes, DateTime? due, int priority) onSave;

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  int _priorityValue = 1;
  bool _saving = false;
  String? _error;
  DateTime? _dueDate;
  TimeOfDay? _dueTime;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    if (task != null) {
      _title.text = task.title;
      _notes.text = task.notes ?? '';
      _priorityValue = task.priority;
      _dueDate = task.dueAt?.toLocal();
      if (_dueDate != null) _dueTime = TimeOfDay.fromDateTime(_dueDate!);
    }
  }

  DateTime? get _due => _dueDate == null ? null : DateTime(
      _dueDate!.year, _dueDate!.month, _dueDate!.day,
      _dueTime?.hour ?? 0, _dueTime?.minute ?? 0);

  Future<void> _pickDate() async {
    FocusScope.of(context).unfocus();
    final initial = _dueDate ?? DateTime.now();
    final date = await showDatePicker(context: context, initialDate: initial,
      firstDate: DateTime(initial.year < 1900 ? initial.year : 1900),
      lastDate: DateTime(initial.year > 2100 ? initial.year : 2100, 12, 31));
    if (mounted && date != null) setState(() => _dueDate = date);
  }

  Future<void> _pickTime() async {
    FocusScope.of(context).unfocus();
    final time = await showTimePicker(context: context,
      initialTime: _dueTime ?? const TimeOfDay(hour: 9, minute: 0),
      initialEntryMode: TimePickerEntryMode.input);
    if (mounted && time != null) setState(() => _dueTime = time);
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() { _saving = true; _error = null; });
    final notes = _notes.text.trim();
    try {
      await widget.onSave(_title.text.trim(), notes.isEmpty ? null : notes, _due, _priorityValue);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save task. Try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(key: _form, child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.task == null ? 'New task' : 'Edit task', style: text.headlineMedium),
                const SizedBox(height: 24),
                TextFormField(
                  key: const ValueKey('task-title'),
                  controller: _title,
                  enabled: !_saving,
                  minLines: 1, maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Title'),
                  validator: (value) => value?.trim().isEmpty != false
                      ? 'Give your task a title.' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('task-notes'),
                  controller: _notes,
                  enabled: !_saving,
                  minLines: 2, maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Notes (optional)'),
                ),
                const SizedBox(height: 24),
                Text('Due (optional)', style: text.titleSmall),
                const SizedBox(height: 8),
                if (_due != null) ...[
                  Text(_dueLabel(context, _due!), style: text.bodyMedium),
                  const SizedBox(height: 8),
                ],
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _saving ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today_rounded, size: 18),
                    label: Text(_dueDate == null ? 'Set due date' : 'Change date'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _saving || _dueDate == null ? null : _pickTime,
                    icon: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(_dueTime == null ? 'Set due time' : 'Change time'),
                  ),
                  if (_dueDate != null)
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _saving ? null : () => setState(() {
                        _dueDate = null; _dueTime = null;
                      }),
                      child: const Text('Remove due date'),
                    ),
                ]),
                const SizedBox(height: 8),
                Text('Due dates don’t create reminders.', style: text.bodySmall),
                const SizedBox(height: 24),
                Text('Priority', style: text.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (var priority = 0; priority <= 2; priority++)
                    Semantics(selected: _priorityValue == priority,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          foregroundColor: priority == 2 ? AppColors.gold : AppColors.ivory,
                          side: BorderSide(color: _priorityValue == priority
                              ? AppColors.lavender : AppColors.muted.withValues(alpha: 0.4)),
                          backgroundColor: _priorityValue == priority
                              ? AppColors.lavender.withValues(alpha: 0.18) : AppColors.surface,
                        ),
                        onPressed: _saving ? null : () => setState(() => _priorityValue = priority),
                        child: Text(_priority(priority)),
                      ),
                    ),
                ]),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  Semantics(liveRegion: true, child: Text(_error!,
                      style: text.bodyMedium?.copyWith(color: AppColors.error))),
                  const SizedBox(height: 16),
                ],
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : _error == null ? 'Save task' : 'Try again'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ]),
              ],
            )),
          ),
        ),
      ),
    );
  }
}

String _priority(int value) => switch (value) {
  0 => 'Low', 1 => 'Normal', 2 => 'High', _ => 'Priority $value',
};

String _dueLabel(BuildContext context, DateTime date) {
  final local = date.toLocal();
  final labels = MaterialLocalizations.of(context);
  return '${labels.formatMediumDate(local)}, ${local.year} · '
      '${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}
