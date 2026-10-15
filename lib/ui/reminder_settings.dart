import 'package:flutter/material.dart';

import '../data/repos.dart';
import '../theme/app_colors.dart';

/// Notification defaults. Each change saves immediately; a failed save shows
/// an error and keeps the last saved values on screen.
class ReminderSettings extends StatefulWidget {
  const ReminderSettings(this.repo, {this.onTest, super.key});
  final ReminderPreferencesRepo repo;

  /// Schedules a short test notification; returns what happened, truthfully.
  final Future<String> Function()? onTest;

  @override
  State<ReminderSettings> createState() => _ReminderSettingsState();
}

class _ReminderSettingsState extends State<ReminderSettings> {
  static const _leadOptions = [5, 10, 15, 30, 60, 120];
  static const _delayOptions = [15, 30, 60, 90, 120, 180];
  ReminderPreferences? _prefs;
  String? _error;
  bool _saving = false;
  String? _testResult;
  bool _testing = false;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await widget.onTest!();
    if (mounted)
      setState(() {
        _testing = false;
        _testResult = r;
      });
  }

  @override
  void initState() {
    super.initState();
    widget.repo.get().then((p) {
      if (mounted) setState(() => _prefs = p);
    }, onError: (Object _) {
      if (mounted) setState(() => _error = 'Couldn’t load reminder settings.');
    });
  }

  Future<void> _save(ReminderPreferences next) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.save(next);
      if (mounted) setState(() => _prefs = next.validated());
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ArgumentError
            ? '${e.message}'
            : 'Couldn’t save reminder settings. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _time(int minutes) => MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

  Future<int?> _pick(int minutes) async {
    final t = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60));
    return t == null ? null : t.hour * 60 + t.minute;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = _prefs;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Reminder notifications', style: text.titleMedium),
      const SizedBox(height: 4),
      Text(
          'Choose preparation nudges and outcome conversations separately. '
          'You can override these defaults for an individual reminder.',
          style: text.bodySmall?.copyWith(color: AppColors.muted)),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style: text.bodyMedium?.copyWith(color: AppColors.error)))),
      if (p == null && _error == null)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator())),
      if (p != null) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Nudge mode'),
          subtitle:
              Text('Alerts ${p.leadMinutes.map((m) => '$m min').join(' and ')} '
                  'before, plus at the time. Past ones are skipped.'),
          value: p.multiple,
          onChanged: _saving ? null : (v) => _save(p.copyWith(multiple: v)),
        ),
        if (p.multiple)
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final m in _leadOptions)
              FilterChip(
                label: Text('$m min before'),
                selected: p.leadMinutes.contains(m),
                onSelected: _saving
                    ? null
                    : (on) {
                        final next = [
                          ...p.leadMinutes.where((x) => x != m),
                          if (on) m
                        ];
                        if (next.isEmpty || next.length > 3) {
                          setState(
                              () => _error = 'Choose 1 to 3 early alerts.');
                          return;
                        }
                        _save(p.copyWith(leadMinutes: next));
                      },
              ),
          ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Follow-ups'),
          subtitle: Text('Ask how events went and review your day at '
              '${_time(p.reviewMinute)}. '
              'Unfinished tasks stay in later evening reviews. '
              'Turning this off cancels scheduled follow-ups.'),
          value: p.followUp,
          onChanged: _saving ? null : (v) => _save(p.copyWith(followUp: v)),
        ),
        if (p.followUp)
          Row(children: [
            const Expanded(child: Text('Estimated event duration')),
            DropdownButton<int>(
              value: _delayOptions.contains(p.followUpMinutes)
                  ? p.followUpMinutes
                  : null,
              hint: Text('${p.followUpMinutes} min'),
              items: [
                for (final m in _delayOptions)
                  DropdownMenuItem(value: m, child: Text('$m min'))
              ],
              onChanged:
                  _saving ? null : (m) => _save(p.copyWith(followUpMinutes: m)),
            ),
          ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Do not disturb'),
          subtitle: Text(p.hasQuietHours
              ? '${_time(p.quietStart!)} – ${_time(p.quietEnd!)}: early alerts and '
                  'follow-ups are skipped. The reminder you asked for still rings.'
              : 'Default sleep hours are 10 PM–7 AM. Without a DND schedule, '
                  'the evening review is at 9:30 PM.'),
          value: p.hasQuietHours,
          onChanged: _saving
              ? null
              : (v) => _save(v
                  ? p.copyWith(quiet: (22 * 60, 7 * 60))
                  : p.copyWith(clearQuiet: true)),
        ),
        if (p.hasQuietHours)
          Wrap(spacing: 8, children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _saving
                  ? null
                  : () async {
                      final m = await _pick(p.quietStart!);
                      if (m != null && mounted)
                        _save(p.copyWith(quiet: (m, p.quietEnd!)));
                    },
              child: Text('Starts ${_time(p.quietStart!)}'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _saving
                  ? null
                  : () async {
                      final m = await _pick(p.quietEnd!);
                      if (m != null && mounted)
                        _save(p.copyWith(quiet: (p.quietStart!, m)));
                    },
              child: Text('Ends ${_time(p.quietEnd!)}'),
            ),
          ]),
      ],
      if (widget.onTest != null) ...[
        const SizedBox(height: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _testing ? null : _test,
          child: const Text('Send a test notification'),
        ),
        if (_testResult != null)
          Semantics(
              liveRegion: true,
              child: Text(_testResult!, style: text.bodySmall)),
      ],
    ]);
  }
}
