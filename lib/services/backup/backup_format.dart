import 'dart:convert';

/// Version of the backup format this build writes and accepts.
///
/// Bump it whenever the data shape changes. [BackupData.formatVersion] carries
/// the same number, so a later build can migrate older backups instead of
/// guessing what a field meant.
const int backupFormatVersion = 1;

/// Tag every Corenyth backup carries in its manifest. A file without it is
/// not a Corenyth backup, whatever else it may contain.
const String backupFormatTag = 'corenyth-backup';

/// App version recorded in the manifest, so an import can tell which build
/// wrote the file.
const String backupAppVersion = '0.1.0-alpha.1+1';

/// File name of a backup inside the models folder.
const String backupFileName = 'backup.corenyth';

/// The two entries a backup archive contains, and nothing else.
const String manifestEntryName = 'manifest.json';
const String dataEntryName = 'data.json';

/// Largest archive accepted on import (bytes). A backup is text, so anything
/// far past this is either not a backup or a decompression bomb.
const int maxBackupBytes = 64 * 1024 * 1024;

/// Largest single JSON entry accepted on import (bytes).
const int maxBackupEntryBytes = 32 * 1024 * 1024;

/// Most rows accepted per table on import.
const int maxBackupRows = 200000;

/// How one stored column maps onto the backup JSON.
enum _Kind { int, intOrNull, text, textOrNull, bool, double, intList }

class _Col {
  final String column;
  final String key;
  final _Kind kind;
  const _Col(this.column, this.key, this.kind);
}

/// One table in the backup: its columns, its primary key and the extra
/// checks that do not fit a column type.
class _Table {
  final String table;
  final String key;
  final List<_Col> cols;

  /// Columns forming the primary key; their values must be unique.
  final List<String> idColumns;

  /// Extra checks (allowed values, ranges) run after the type checks.
  final void Function(Map<String, Object?> row, List<String> errors)? check;

  const _Table(this.table, this.key, this.cols, this.idColumns,
      {this.check});
}

// --- the tables ---------------------------------------------------------

const _tables = <_Table>[
  _Table(
    'tasks',
    'tasks',
    [
      _Col('id', 'id', _Kind.int),
      _Col('title', 'title', _Kind.text),
      _Col('notes', 'notes', _Kind.textOrNull),
      _Col('status', 'status', _Kind.text),
      _Col('created_at', 'createdAt', _Kind.int),
      _Col('due_at', 'dueAt', _Kind.intOrNull),
      _Col('completed_at', 'completedAt', _Kind.intOrNull),
      _Col('priority', 'priority', _Kind.int),
      _Col('recurrence', 'recurrence', _Kind.textOrNull),
      _Col('ends_at', 'endsAt', _Kind.intOrNull),
      _Col('subject', 'subject', _Kind.textOrNull),
      _Col('deadline_at', 'deadlineAt', _Kind.intOrNull),
      _Col('outcome', 'outcome', _Kind.textOrNull),
      _Col('awaiting', 'awaiting', _Kind.textOrNull),
      _Col('awaiting_at', 'awaitingAt', _Kind.intOrNull),
      _Col('daily_minute', 'dailyMinute', _Kind.intOrNull),
      _Col('alert_plan', 'alertPlan', _Kind.textOrNull),
      _Col('op_id', 'opId', _Kind.textOrNull),
    ],
    ['id'],
    check: _checkTask,
  ),
  _Table(
    'reminders',
    'reminders',
    [
      _Col('id', 'id', _Kind.int),
      _Col('task_id', 'taskId', _Kind.intOrNull),
      _Col('title', 'title', _Kind.text),
      _Col('trigger_at', 'triggerAt', _Kind.int),
      _Col('enabled', 'enabled', _Kind.bool),
      _Col('kind', 'kind', _Kind.text),
      _Col('sync', 'sync', _Kind.textOrNull),
      _Col('op_id', 'opId', _Kind.textOrNull),
    ],
    ['id'],
    check: _checkReminder,
  ),
  _Table(
    'chats',
    'chats',
    [
      _Col('id', 'id', _Kind.text),
      _Col('title', 'title', _Kind.text),
      _Col('created_at', 'createdAt', _Kind.int),
      _Col('updated_at', 'updatedAt', _Kind.int),
    ],
    ['id'],
  ),
  _Table(
    'conversations',
    'conversations',
    [
      _Col('id', 'id', _Kind.int),
      _Col('session_id', 'sessionId', _Kind.text),
      _Col('role', 'role', _Kind.text),
      _Col('content', 'content', _Kind.text),
      _Col('created_at', 'createdAt', _Kind.int),
      _Col('task_id', 'taskId', _Kind.intOrNull),
      _Col('kind', 'kind', _Kind.textOrNull),
    ],
    ['id'],
    check: _checkConversation,
  ),
  _Table(
    'memories',
    'memories',
    [
      _Col('id', 'id', _Kind.int),
      _Col('content', 'content', _Kind.text),
      _Col('category', 'category', _Kind.text),
      _Col('importance', 'importance', _Kind.double),
      _Col('created_at', 'createdAt', _Kind.int),
      _Col('updated_at', 'updatedAt', _Kind.int),
      _Col('last_accessed_at', 'lastAccessedAt', _Kind.intOrNull),
      _Col('op_id', 'opId', _Kind.textOrNull),
      _Col('source', 'source', _Kind.textOrNull),
      _Col('status', 'status', _Kind.text),
      _Col('superseded_by', 'supersededBy', _Kind.intOrNull),
    ],
    ['id'],
    check: _checkMemory,
  ),
  _Table(
    'pending_clarifications',
    'pendingClarifications',
    [
      _Col('chat_id', 'chatId', _Kind.text),
      _Col('draft', 'draft', _Kind.text),
      _Col('updated_at', 'updatedAt', _Kind.int),
    ],
    ['chat_id'],
  ),
  _Table(
    'proactive_events',
    'proactiveEvents',
    [
      _Col('key', 'key', _Kind.text),
      _Col('task_id', 'taskId', _Kind.intOrNull),
      _Col('created_at', 'createdAt', _Kind.int),
    ],
    ['key'],
  ),
  _Table(
    'review_items',
    'reviewItems',
    [
      _Col('day', 'day', _Kind.text),
      _Col('task_id', 'taskId', _Kind.int),
      _Col('answered', 'answered', _Kind.bool),
    ],
    ['day', 'task_id'],
  ),
  _Table(
    'operations',
    'operations',
    [
      _Col('op_id', 'opId', _Kind.text),
      _Col('chat_id', 'chatId', _Kind.text),
      _Col('text_hash', 'textHash', _Kind.text),
      _Col('status', 'status', _Kind.text),
      _Col('action', 'action', _Kind.textOrNull),
      _Col('receipt', 'receipt', _Kind.textOrNull),
      _Col('created_at', 'createdAt', _Kind.int),
      _Col('updated_at', 'updatedAt', _Kind.int),
    ],
    ['op_id'],
  ),
];

void _checkTask(Map<String, Object?> r, List<String> errors) {
  final status = r['status'];
  if (status != 'pending' && status != 'done') {
    errors.add('Task ${r['id']}: status must be "pending" or "done".');
  }
  final priority = r['priority'];
  if (priority is! int || priority < 0 || priority > 2) {
    errors.add('Task ${r['id']}: priority must be 0, 1 or 2.');
  }
  final awaiting = r['awaiting'];
  if (awaiting != null && awaiting != 'details' && awaiting != 'outcome') {
    errors.add('Task ${r['id']}: awaiting must be "details" or "outcome".');
  }
}

void _checkReminder(Map<String, Object?> r, List<String> errors) {
  final kind = r['kind'];
  if (kind != 'reminder' && kind != 'pre' && kind != 'follow_up') {
    errors.add('Reminder ${r['id']}: kind must be "reminder", "pre" or '
        '"follow_up".');
  }
  final sync = r['sync'];
  if (sync != null && sync != 'schedule' && sync != 'cancel') {
    errors.add('Reminder ${r['id']}: sync must be "schedule", "cancel" or '
        'null.');
  }
}

void _checkConversation(Map<String, Object?> r, List<String> errors) {
  final role = r['role'];
  if (role != 'user' && role != 'assistant') {
    errors.add('Message ${r['id']}: role must be "user" or "assistant".');
  }
}

void _checkMemory(Map<String, Object?> r, List<String> errors) {
  final status = r['status'];
  if (status != 'active' && status != 'superseded') {
    errors.add('Memory ${r['id']}: status must be "active" or "superseded".');
  }
  final importance = r['importance'];
  if (importance is! num || importance < 0.0 || importance > 1.0) {
    errors.add('Memory ${r['id']}: importance must be between 0 and 1.');
  }
}

/// The manifest: what this file is, when it was made and how much it holds.
class BackupManifest {
  final int formatVersion;
  final String appVersion;
  final DateTime createdAt;
  final Map<String, int> counts;

  BackupManifest(
      {this.formatVersion = backupFormatVersion,
      this.appVersion = backupAppVersion,
      required this.createdAt,
      required this.counts});

  Map<String, Object?> toJson() => {
        'format': backupFormatTag,
        'formatVersion': formatVersion,
        'appVersion': appVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'counts': counts,
      };

  /// Parses the manifest, adding a readable reason to [errors] on failure.
  /// Returns null when the manifest cannot be used.
  static BackupManifest? parse(Object? raw, List<String> errors) {
    if (raw is! Map) {
      errors.add('The manifest is not a JSON object.');
      return null;
    }
    final map = raw.cast<Object?, Object?>();
    if (map['format'] != backupFormatTag) {
      errors.add('This is not a Corenyth backup file.');
      return null;
    }
    final version = map['formatVersion'];
    if (version is! int) {
      errors.add('The backup does not say which format version it uses.');
      return null;
    }
    if (version != backupFormatVersion) {
      errors.add('This backup uses format version $version; this version of '
          'Corenyth reads version $backupFormatVersion only.');
      return null;
    }
    final appVersion = map['appVersion'];
    if (appVersion != null && appVersion is! String) {
      errors.add('The backup has an unreadable app version.');
      return null;
    }
    final created = map['createdAt'];
    if (created is! String) {
      errors.add('The backup does not say when it was created.');
      return null;
    }
    final at = DateTime.tryParse(created);
    if (at == null) {
      errors.add('The backup has an unreadable creation date.');
      return null;
    }
    final rawCounts = map['counts'];
    final counts = <String, int>{};
    if (rawCounts is Map) {
      for (final entry in rawCounts.entries) {
        final v = entry.value;
        if (v is int) counts['${entry.key}'] = v;
      }
    }
    return BackupManifest(
        formatVersion: version,
        appVersion: appVersion as String? ?? backupAppVersion,
        createdAt: at.toUtc(),
        counts: counts);
  }
}

/// The user's saved context, as read from the database.
///
/// Rows are kept as column maps (`column` → value in database form) so the
/// restore can insert them without a second translation step. The column
/// names are the ones in `lib/data/db.dart`.
class BackupData {
  final int formatVersion;

  /// The single profile row, or null when the backup had none.
  final Map<String, Object?>? profile;

  /// The single preferences row, or null when the backup had none (which
  /// means the default quiet hours, per `lib/data/repos.dart`).
  final Map<String, Object?>? preferences;

  /// The chosen model id (an allowlisted id, not a path or a binary), or null.
  final String? selectedModelId;

  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> reminders;
  final List<Map<String, Object?>> chats;
  final List<Map<String, Object?>> conversations;
  final List<Map<String, Object?>> memories;
  final List<Map<String, Object?>> pendingClarifications;
  final List<Map<String, Object?>> proactiveEvents;
  final List<Map<String, Object?>> reviewItems;
  final List<Map<String, Object?>> operations;

  BackupData({
    this.formatVersion = backupFormatVersion,
    this.profile,
    this.preferences,
    this.selectedModelId,
    this.tasks = const [],
    this.reminders = const [],
    this.chats = const [],
    this.conversations = const [],
    this.memories = const [],
    this.pendingClarifications = const [],
    this.proactiveEvents = const [],
    this.reviewItems = const [],
    this.operations = const [],
  });

  /// Rows of one table by its JSON key.
  List<Map<String, Object?>> rowsOf(String key) => switch (key) {
        'tasks' => tasks,
        'reminders' => reminders,
        'chats' => chats,
        'conversations' => conversations,
        'memories' => memories,
        'pendingClarifications' => pendingClarifications,
        'proactiveEvents' => proactiveEvents,
        'reviewItems' => reviewItems,
        'operations' => operations,
        _ => const [],
      };

  /// How many rows each table holds, for the manifest.
  Map<String, int> counts() => {
        'chats': chats.length,
        'conversations': conversations.length,
        'memories': memories.length,
        'operations': operations.length,
        'pendingClarifications': pendingClarifications.length,
        'preferences': preferences == null ? 0 : 1,
        'profile': profile == null ? 0 : 1,
        'proactiveEvents': proactiveEvents.length,
        'reminders': reminders.length,
        'reviewItems': reviewItems.length,
        'tasks': tasks.length,
      };

  Map<String, Object?> toJson() => {
        'formatVersion': formatVersion,
        'profile': profile == null
            ? null
            : {
                'name': profile!['name'],
                'occupation': profile!['occupation'],
                'tone': profile!['tone'],
                'onboardingComplete': profile!['onboarding_complete'] == 1,
              },
        'preferences': preferences == null
            ? null
            : {
                'multiple': preferences!['multiple'] == 1,
                'followUp': preferences!['follow_up'] == 1,
                'leadMinutes': _leads(preferences!['lead_minutes'] as String?),
                'followUpMinutes': preferences!['follow_up_minutes'],
                'quietStart': preferences!['quiet_start'],
                'quietEnd': preferences!['quiet_end'],
              },
        'model': {'selectedId': selectedModelId},
        for (final t in _tables)
          t.key: [
            for (final r in rowsOf(t.key)) rowToJson(t, r)
          ],
      };
}

/// The stored lead offsets, as a list of minutes.
List<int> _leads(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toList(growable: false);
}

/// A backup that was read and checked, ready to be shown to the user and
/// then applied.
class BackupPreview {
  final BackupManifest manifest;
  final BackupData data;

  /// Where the file was read from (a copy in the app cache, not the original).
  final String sourcePath;

  BackupPreview(this.manifest, this.data, this.sourcePath);

  /// The backup's creation date in UTC.
  DateTime get createdAt => manifest.createdAt;
}

/// The outcome of an export or an import.
class BackupResult {
  /// Where the archive was written.
  final String path;

  /// The rows it holds.
  final Map<String, int> counts;

  /// When the archive was written.
  final DateTime createdAt;

  /// True for the automatic recovery copy taken before an import.
  final bool isRecovery;

  BackupResult(this.path, this.counts, this.createdAt,
      {this.isRecovery = false});

  /// A one-line summary for the UI.
  String get summary {
    final n = counts.values.fold<int>(0, (a, b) => a + b);
    return '$n record${n == 1 ? '' : 's'} saved';
  }
}

/// Reads a backup's `data.json` into [BackupData], collecting every problem
/// it finds instead of throwing on the first one.
///
/// Returns null when [errors] is not empty; the caller shows them as-is.
BackupData? parseBackupData(Object? raw, List<String> errors) {
  if (raw is! Map) {
    errors.add('The backup data is not a JSON object.');
    return null;
  }
  final map = raw.cast<Object?, Object?>();
  final version = map['formatVersion'];
  if (version is! int) {
    errors.add('The backup data does not say which format version it uses.');
    return null;
  }
  if (version != backupFormatVersion) {
    errors.add('This backup uses format version $version; this version of '
        'Corenyth reads version $backupFormatVersion only.');
    return null;
  }

  final rows = <String, List<Map<String, Object?>>>{};
  for (final spec in _tables) {
    final value = map[spec.key];
    if (value == null) {
      errors.add('The backup has no "${spec.key}" section.');
      return null;
    }
    if (value is! List) {
      errors.add('The "${spec.key}" section is not a list.');
      return null;
    }
    if (value.length > maxBackupRows) {
      errors.add('The "${spec.key}" section has ${value.length} rows; at most '
          '$maxBackupRows are accepted.');
      return null;
    }
    final parsed = <Map<String, Object?>>[];
    for (final entry in value) {
      if (entry is! Map) {
        errors.add('The "${spec.key}" section holds an entry that is not an '
            'object.');
        return null;
      }
      final row = _parseRow(spec, entry.cast<Object?, Object?>(), errors);
      if (row == null) return null;
      parsed.add(row);
    }
    rows[spec.key] = parsed;
  }

  final profile = _parseProfile(map['profile'], errors);
  final preferences = _parsePreferences(map['preferences'], errors);
  if (errors.isNotEmpty) return null;

  final model = map['model'];
  String? modelId;
  if (model is Map) {
    final id = model['selectedId'];
    if (id != null && id is! String) {
      errors.add('The backup has an unreadable model choice.');
      return null;
    }
    modelId = id as String?;
  } else if (model != null) {
    errors.add('The backup has an unreadable model choice.');
    return null;
  }

  final data = BackupData(
      formatVersion: version,
      profile: profile,
      preferences: preferences,
      selectedModelId: modelId,
      tasks: rows['tasks']!,
      reminders: rows['reminders']!,
      chats: rows['chats']!,
      conversations: rows['conversations']!,
      memories: rows['memories']!,
      pendingClarifications: rows['pendingClarifications']!,
      proactiveEvents: rows['proactiveEvents']!,
      reviewItems: rows['reviewItems']!,
      operations: rows['operations']!);

  _checkRelations(data, errors);
  if (errors.isNotEmpty) return null;
  return data;
}

/// One row of one table, in database form, or null with the reason in
/// [errors].
Map<String, Object?>? _parseRow(
    _Table spec, Map<Object?, Object?> raw, List<String> errors) {
  final row = <String, Object?>{};
  for (final col in spec.cols) {
    if (!raw.containsKey(col.key)) {
      errors.add('A ${spec.key} entry is missing "${col.key}".');
      return null;
    }
    final value = raw[col.key];
    switch (col.kind) {
      case _Kind.int:
        if (value is! int) {
          errors.add('A ${spec.key} entry has a non-numeric "${col.key}".');
          return null;
        }
        row[col.column] = value;
      case _Kind.intOrNull:
        if (value != null && value is! int) {
          errors.add('A ${spec.key} entry has a non-numeric "${col.key}".');
          return null;
        }
        row[col.column] = value as int?;
      case _Kind.text:
        if (value is! String) {
          errors.add('A ${spec.key} entry has a non-text "${col.key}".');
          return null;
        }
        row[col.column] = value;
      case _Kind.textOrNull:
        if (value != null && value is! String) {
          errors.add('A ${spec.key} entry has a non-text "${col.key}".');
          return null;
        }
        row[col.column] = value as String?;
      case _Kind.bool:
        if (value is! bool) {
          errors.add('A ${spec.key} entry has a non-boolean "${col.key}".');
          return null;
        }
        row[col.column] = value ? 1 : 0;
      case _Kind.double:
        if (value is! num) {
          errors.add('A ${spec.key} entry has a non-numeric "${col.key}".');
          return null;
        }
        row[col.column] = value.toDouble();
      case _Kind.intList:
        if (value is! List) {
          errors.add('A ${spec.key} entry has a non-list "${col.key}".');
          return null;
        }
        final ints = <int>[];
        for (final v in value) {
          if (v is! int) {
            errors.add('A ${spec.key} entry has a non-numeric "${col.key}".');
            return null;
          }
          ints.add(v);
        }
        row[col.column] = ints;
    }
  }
  spec.check?.call(row, errors);
  if (errors.isNotEmpty) return null;

  // Primary key: present, and unique within the table.
  for (final c in spec.idColumns) {
    final v = row[c];
    if (v is int && v <= 0) {
      errors.add('A ${spec.key} entry has a non-positive id.');
      return null;
    }
    if (v is String && v.trim().isEmpty) {
      errors.add('A ${spec.key} entry has an empty id.');
      return null;
    }
  }
  return row;
}

/// The ids of a table, for the relationship checks.
Set<Object> _idsOf(List<Map<String, Object?>> rows, String column) =>
    {for (final r in rows) r[column] as Object};

/// Rejects relationships that point at nothing: a broken link is a corrupt
/// backup, never something to drop silently.
void _checkRelations(BackupData d, List<String> errors) {
  final taskIds = _idsOf(d.tasks, 'id');
  final chatIds = _idsOf(d.chats, 'id');
  final memoryIds = _idsOf(d.memories, 'id');
  final opIds = _idsOf(d.operations, 'op_id');

  for (final r in d.reminders) {
    final t = r['task_id'];
    if (t != null && !taskIds.contains(t)) {
      errors.add('Reminder ${r['id']} points at a task that is not in the '
          'backup.');
    }
    final op = r['op_id'];
    if (op != null && !opIds.contains(op)) {
      errors.add('Reminder ${r['id']} points at a turn that is not in the '
          'backup.');
    }
  }
  for (final r in d.conversations) {
    final session = r['session_id'];
    if (session != null && !chatIds.contains(session)) {
      errors.add('Message ${r['id']} points at a chat that is not in the '
          'backup.');
    }
    final t = r['task_id'];
    if (t != null && !taskIds.contains(t)) {
      errors.add('Message ${r['id']} points at a task that is not in the '
          'backup.');
    }
  }
  for (final r in d.memories) {
    final s = r['superseded_by'];
    if (s != null && !memoryIds.contains(s)) {
      errors.add('Memory ${r['id']} points at a memory that is not in the '
          'backup.');
    }
  }
  for (final r in d.proactiveEvents) {
    final t = r['task_id'];
    if (t != null && !taskIds.contains(t)) {
      errors.add('A delivered check-in points at a task that is not in the '
          'backup.');
    }
  }
  for (final r in d.reviewItems) {
    final t = r['task_id'];
    if (t != null && !taskIds.contains(t)) {
      errors.add('A review entry points at a task that is not in the backup.');
    }
  }
  for (final r in d.tasks) {
    final op = r['op_id'];
    if (op != null && !opIds.contains(op)) {
      errors.add('Task ${r['id']} points at a turn that is not in the backup.');
    }
  }
}

/// The profile row, or null when the backup had none.
Map<String, Object?>? _parseProfile(Object? raw, List<String> errors) {
  if (raw == null) return null;
  if (raw is! Map) {
    errors.add('The profile is not a JSON object.');
    return null;
  }
  final map = raw.cast<Object?, Object?>();
  final name = map['name'];
  final occupation = map['occupation'];
  final tone = map['tone'];
  final onboarding = map['onboardingComplete'];
  if (name is! String || occupation is! String || tone is! String) {
    errors.add('The profile is missing its name, occupation or tone.');
    return null;
  }
  if (onboarding is! bool) {
    errors.add('The profile is missing its "onboardingComplete" flag.');
    return null;
  }
  return {
    'id': 1,
    'name': name,
    'occupation': occupation,
    'tone': tone,
    'onboarding_complete': onboarding ? 1 : 0,
  };
}

/// The preferences row, or null when the backup had none.
Map<String, Object?>? _parsePreferences(Object? raw, List<String> errors) {
  if (raw == null) return null;
  if (raw is! Map) {
    errors.add('The preferences are not a JSON object.');
    return null;
  }
  final map = raw.cast<Object?, Object?>();
  final multiple = map['multiple'];
  final followUp = map['followUp'];
  final leads = map['leadMinutes'];
  final followUpMinutes = map['followUpMinutes'];
  final quietStart = map['quietStart'];
  final quietEnd = map['quietEnd'];
  if (multiple is! bool || followUp is! bool) {
    errors.add('The preferences are missing their nudge or follow-up switch.');
    return null;
  }
  if (leads is! List) {
    errors.add('The preferences are missing their early-alert minutes.');
    return null;
  }
  final leadList = <int>[];
  for (final v in leads) {
    if (v is! int) {
      errors.add('The preferences have a non-numeric early-alert minute.');
      return null;
    }
    leadList.add(v);
  }
  if (leadList.isEmpty || leadList.length > 3) {
    errors.add('The preferences need 1 to 3 early alerts.');
    return null;
  }
  if (leadList.any((m) => m < 1 || m > 1440)) {
    errors.add('Early alerts must be between 1 and 1440 minutes.');
    return null;
  }
  if (followUpMinutes is! int || followUpMinutes < 5 || followUpMinutes > 1440) {
    errors.add('The follow-up delay must be between 5 and 1440 minutes.');
    return null;
  }
  for (final q in [quietStart, quietEnd]) {
    if (q != null && (q is! int || q < 0 || q >= 1440)) {
      errors.add('Quiet hours must be minutes after midnight (0-1439).');
      return null;
    }
  }
  if ((quietStart == null) != (quietEnd == null)) {
    errors.add('Quiet hours need both a start and an end.');
    return null;
  }
  return {
    'id': 1,
    'multiple': multiple ? 1 : 0,
    'follow_up': followUp ? 1 : 0,
    'lead_minutes': leadList.join(','),
    'follow_up_minutes': followUpMinutes,
    'quiet_start': quietStart as int?,
    'quiet_end': quietEnd as int?,
  };
}

/// JSON text of the manifest, for writing into the archive.
String encodeManifest(BackupManifest m) =>
    const JsonEncoder.withIndent('  ').convert(m.toJson());

/// JSON text of the data, for writing into the archive.
String encodeData(BackupData d) =>
    const JsonEncoder.withIndent('  ').convert(d.toJson());

/// Builds the [BackupData] for a set of database rows, in database form.
/// Used by the export; the rows come from one transaction, so the snapshot
/// is consistent.
BackupData buildBackupData({
  required List<Map<String, Object?>> tasks,
  required List<Map<String, Object?>> reminders,
  required List<Map<String, Object?>> chats,
  required List<Map<String, Object?>> conversations,
  required List<Map<String, Object?>> memories,
  required List<Map<String, Object?>> pendingClarifications,
  required List<Map<String, Object?>> proactiveEvents,
  required List<Map<String, Object?>> reviewItems,
  required List<Map<String, Object?>> operations,
  Map<String, Object?>? profile,
  Map<String, Object?>? preferences,
  String? selectedModelId,
}) =>
    BackupData(
        profile: profile,
        preferences: preferences,
        selectedModelId: selectedModelId,
        tasks: tasks,
        reminders: reminders,
        chats: chats,
        conversations: conversations,
        memories: memories,
        pendingClarifications: pendingClarifications,
        proactiveEvents: proactiveEvents,
        reviewItems: reviewItems,
        operations: operations);

/// The JSON form of one database row, per the table's column spec.
Map<String, Object?> rowToJson(_Table spec, Map<String, Object?> row) {
  final out = <String, Object?>{};
  for (final col in spec.cols) {
    final v = row[col.column];
    switch (col.kind) {
      case _Kind.bool:
        out[col.key] = v == 1;
      case _Kind.double:
        out[col.key] = (v as num?)?.toDouble();
      case _Kind.intList:
        out[col.key] = _leads(v as String?);
      case _Kind.int:
      case _Kind.text:
        out[col.key] = v;
      case _Kind.intOrNull:
      case _Kind.textOrNull:
        out[col.key] = v;
    }
  }
  return out;
}

/// The table spec for a JSON key, or null when the key is unknown.
_Table? specFor(String key) {
  for (final t in _tables) {
    if (t.key == key) return t;
  }
  return null;
}

/// All table specs, in the order they are written and read.
List<_Table> get backupTables => _tables;
