import 'package:flutter/material.dart';

import '../services/backup/backup_format.dart';
import '../services/backup/backup_gateway.dart';
import '../services/backup/backup_service.dart';
import '../theme/app_colors.dart';

/// Backup and restore. A backup is a copy of everything Corenyth remembers
/// about the user, so it can move to another phone.
///
/// The file is plain: it holds personal data and is not password protected.
class BackupSettings extends StatefulWidget {
  const BackupSettings(this.service, {this.onImported, super.key});

  final BackupService service;

  /// Called after a successful import, so the app can reload what it shows.
  final VoidCallback? onImported;

  @override
  State<BackupSettings> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends State<BackupSettings> {
  bool _busy = false;
  String? _error;
  String? _status;
  bool _statusIsError = false;
  String? _sharePath;
  Map<String, int>? _counts;

  @override
  void initState() {
    super.initState();
    widget.service.busy.addListener(_onBusy);
  }

  @override
  void dispose() {
    widget.service.busy.removeListener(_onBusy);
    super.dispose();
  }

  void _onBusy() {
    if (mounted) setState(() => _busy = widget.service.busy.value);
  }

  void _say(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _error = isError ? message : null;
      _status = isError ? null : message;
      _statusIsError = isError;
    });
  }

  /// A short "3 tasks, 12 messages" style summary of the counts.
  String _summaryOf(Map<String, int> counts) {
    final parts = <String>[];
    void add(String label, String key) {
      final n = counts[key] ?? 0;
      if (n > 0) parts.add('$n $label${n == 1 ? '' : 's'}');
    }

    add('task', 'tasks');
    add('reminder', 'reminders');
    add('chat', 'chats');
    add('message', 'conversations');
    add('memory', 'memories');
    if (parts.isEmpty) return 'No records';
    return parts.join(', ');
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Creating backup…';
      _statusIsError = false;
    });
    try {
      final result = await widget.service.exportBackup();
      if (!mounted) return;
      setState(() {
        _status = 'Backup saved.';
        _statusIsError = false;
        _sharePath = result.path;
        _counts = result.counts;
      });
    } on BackupFileException catch (e) {
      _say(e.message, isError: true);
    } on BackupException catch (e) {
      _say(e.message, isError: true);
    } catch (e) {
      _say('The backup could not be created. Try again.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final path = _sharePath;
    if (path == null || _busy) return;
    setState(() => _busy = true);
    try {
      final shared = await widget.service.gateway.shareBackupFile(path);
      _say(shared
          ? 'Choose where to send the backup. Send it to yourself to move it '
              'to another phone.'
          : 'No app on this device can receive the backup.');
    } on BackupFileException catch (e) {
      _say(e.message, isError: true);
    } catch (_) {
      _say('The backup could not be shared.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Opening the file picker…';
      _statusIsError = false;
    });
    BackupPreview? preview;
    try {
      preview = await widget.service.pickAndCheck();
    } on BackupFileException catch (e) {
      _say(e.message, isError: true);
      if (mounted) setState(() => _busy = false);
      return;
    } on BackupException catch (e) {
      _say(e.message, isError: true);
      if (mounted) setState(() => _busy = false);
      return;
    } catch (e) {
      _say('That file could not be opened. Try again.', isError: true);
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (preview == null) {
      // The user cancelled the picker: nothing happened, and that is fine.
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = 'Checking the backup…';
    });
    final confirmed = await _confirm(preview);
    if (!confirmed) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = 'Restoring your data…';
    });
    try {
      final result = await widget.service.importBackup(preview);
      if (!mounted) return;
      setState(() {
        _status = 'Your data was restored. A copy of your previous data is '
            'saved as ${result.path}.';
        _statusIsError = false;
        _counts = result.counts;
      });
      widget.onImported?.call();
    } on BackupException catch (e) {
      _say(e.message, isError: true);
    } catch (e) {
      _say('The backup could not be imported. Your data was not changed.',
          isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The confirmation: what the backup holds, and that it replaces
  /// everything on this device.
  Future<bool> _confirm(BackupPreview preview) async {
    final text = Theme.of(context).textTheme;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace your data?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Backup from ${_date(preview.createdAt)}',
                  style: text.titleSmall),
              const SizedBox(height: 8),
              Text(_summaryOf(preview.manifest.counts),
                  style: text.bodySmall),
              const SizedBox(height: 16),
              Text(
                  'Importing replaces everything Corenyth knows on this '
                  'device: your chats, tasks, reminders, memories and '
                  'settings. A copy of your current data is saved first.',
                  style: text.bodyMedium),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import')),
        ],
      ),
    );
    return answer == true;
  }

  /// The creation date, in the user's own words.
  String _date(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Backup & restore', style: text.titleMedium),
      const SizedBox(height: 4),
      Text(
          'A backup holds your chats, tasks, reminders, memories and settings, '
          'so you can move them to another phone.',
          style: text.bodySmall?.copyWith(color: AppColors.muted)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : _create,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.backup_outlined),
        label: Text(_busy ? 'Working…' : 'Create backup'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.restore_outlined),
        label: const Text('Import backup'),
      ),
      if (_sharePath != null) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _share,
          icon: const Icon(Icons.ios_share),
          label: const Text('Share backup'),
        ),
      ],
      if (_status != null) ...[
        const SizedBox(height: 12),
        Semantics(
            liveRegion: true,
            child: Text(_status!,
                style: text.bodyMedium
                    ?.copyWith(color: _statusIsError ? AppColors.error : null))),
      ],
      if (_error != null) ...[
        const SizedBox(height: 8),
        Semantics(
            liveRegion: true,
            child: Text(_error!,
                style: text.bodyMedium?.copyWith(color: AppColors.error))),
      ],
      if (_sharePath != null) ...[
        const SizedBox(height: 12),
        Text('Saved to', style: text.bodySmall),
        Text(_sharePath!, style: text.bodySmall),
      ],
      if (_counts != null && _status != null) ...[
        const SizedBox(height: 4),
        Text(_summaryOf(_counts!), style: text.bodySmall),
      ],
      const SizedBox(height: 12),
      Text(
          'The backup file contains your personal data and is not password '
          'protected. Anyone who has it can read it.',
          style: text.bodySmall?.copyWith(color: AppColors.gold)),
    ]);
  }
}
