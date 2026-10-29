// Shared evaluation fixture support for single- and multi-turn corpus runs.
import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/core_policy.dart';
import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/assistant/turn_contract.dart'
    show TurnRecord, defaultInterpreter;
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records schedule/cancel/delivery requests without delivering notifications.
class RecordingScheduler extends NoopScheduler {
  RecordingScheduler({this.issue});

  /// When non-null, [deliveryIssue] reports this (e.g. notifications denied).
  String? issue;
  final scheduled = <Map<String, Object?>>[];
  final cancelled = <int>[];
  final deliveryRequests = <Map<String, Object?>>[];

  @override
  Future<void> schedule(Reminder r) async {
    scheduled.add({
      'id': r.id,
      'title': r.title,
      'trigger_at': r.triggerAt.toIso8601String(),
      'kind': r.kind,
      'enabled': r.enabled,
    });
    deliveryRequests.add({'action': 'schedule', 'id': r.id});
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    deliveryRequests.add({'action': 'cancel', 'id': id});
  }

  @override
  Future<String?> deliveryIssue() async => issue;
}

class EvalFixture {
  EvalFixture({
    required this.db,
    required this.path,
    required this.tasks,
    required this.reminders,
    required this.memory,
    required this.conversations,
    required this.pending,
    required this.operations,
    required this.prefs,
    required this.profile,
    required this.scheduler,
    required this.refs,
    required this.policyStore,
  });

  final Database db;
  final String path;
  final TaskRepo tasks;
  final ReminderRepo reminders;
  final MemoryRepo memory;
  final ConversationRepo conversations;
  final PendingRepo pending;
  final OperationJournal operations;
  final ReminderPreferencesRepo prefs;
  final ProfileRepo profile;
  final RecordingScheduler scheduler;
  final Map<String, Map<String, dynamic>> refs;
  final CorePolicyStore policyStore;

  Future<Map<String, dynamic>> snapshot() async => {
        for (final table in [
          'tasks',
          'reminders',
          'memories',
          'pending_clarifications',
          'operations',
          'conversations'
        ])
          table: await db.query(table)
      };

  Future<AssistantSession> openSession({
    required String chatId,
    required DateTime Function() clock,
    required LlmEngine engine,
  }) async {
    final session = AssistantSession(
      engine: engine,
      tools: ToolExecutor(
          tasks, ReminderRepo(db, clock: clock), memory, scheduler,
          clock: clock, preferences: prefs),
      memory: memory,
      profile: profile,
      taskRepo: tasks,
      conversations: conversations,
      pending: pending,
      operations: operations,
      conversationId: chatId,
      clock: clock,
      policyStore: policyStore,
    );
    await session.start();
    return session;
  }

  Future<void> closeDb() async {
    await db.close();
  }
}

/// Creates a disposable production-schema database and applies [setup].
/// Unknown setup fields throw rather than being ignored.
Future<EvalFixture> openEvalFixture({
  required String directory,
  required String name,
  required Map<String, dynamic> setup,
  required DateTime now,
  String? notificationIssue,
}) async {
  final path = '$directory/$name.db';
  final db = await openAppDb(path: path);
  final tasks = TaskRepo(db);
  final reminders = ReminderRepo(db);
  final memory = MemoryRepo(db);
  final conversations = ConversationRepo(db);
  final pending = PendingRepo(db);
  final operations = OperationJournal(db);
  final prefs = ReminderPreferencesRepo(db);
  final profile = ProfileRepo(db);
  final refs = <String, Map<String, dynamic>>{};
  final scheduler = RecordingScheduler(issue: notificationIssue);

  for (final key in setup.keys) {
    if (!const {
      'tasks',
      'reminders',
      'memories',
      'history',
      'prefs',
      'env',
      'pending'
    }.contains(key)) {
      throw StateError('unsupported setup field: $key');
    }
  }

  for (final t in setup['tasks'] as List? ?? []) {
    final row = Map<String, dynamic>.from(t as Map);
    final v = await tasks.create(row['title'] as String,
        due: row['due'] == null ? null : DateTime.parse(row['due'] as String));
    if (row['done'] == true) await tasks.complete(v.id);
    if (row['awaiting'] != null) {
      await tasks.setAwaiting(v.id, row['awaiting'] as String);
    }
    refs[row['ref'] as String] = {'table': 'tasks', 'id': v.id};
  }

  for (final r in setup['reminders'] as List? ?? []) {
    final row = Map<String, dynamic>.from(r as Map);
    final kind = row['kind'] as String? ?? 'main';
    if (!const {'main', 'pre', 'follow_up'}.contains(kind)) {
      throw StateError('unsupported reminder kind: $kind');
    }
    final v = await reminders.create(
        row['title'] as String, DateTime.parse(row['at'] as String),
        taskId: refs[row['task']]?['id'] as int?);
    final dbKind = kind == 'main' ? 'reminder' : kind;
    if (dbKind != 'reminder') {
      await reminders.update(v.id, {'kind': dbKind});
    }
    refs[row['ref'] as String] = {'table': 'reminders', 'id': v.id};
  }

  for (final m in setup['memories'] as List? ?? []) {
    final row = Map<String, dynamic>.from(m as Map);
    final id = await memory.add(row['content'] as String,
        category: row['category'] as String? ?? 'fact');
    refs[row['ref'] as String] = {'table': 'memories', 'id': id};
  }

  for (final h in setup['history'] as List? ?? []) {
    final row = Map<String, dynamic>.from(h as Map);
    for (final key in row.keys) {
      if (!const {'chat', 'role', 'content', 'kind', 'time', 'minutes_ago'}
          .contains(key)) {
        throw StateError('unsupported history field: $key');
      }
    }
    final chat = row['chat'] as String? ?? 'eval';
    final role = row['role'] as String;
    final content = row['content'] as String;
    final kind = row['kind'] as String?;
    var created = now;
    if (row['minutes_ago'] != null) {
      created = now.subtract(Duration(minutes: row['minutes_ago'] as int));
    } else if (row['time'] != null) {
      created = DateTime.parse(row['time'] as String);
    }
    final t = created.millisecondsSinceEpoch;
    await db.transaction((tx) async {
      await tx.insert('conversations', {
        'session_id': chat,
        'role': role,
        'content': content,
        'created_at': t,
        if (kind != null) 'kind': kind,
      });
      await tx.insert(
          'chats', {'id': chat, 'title': '', 'created_at': t, 'updated_at': t},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.rawUpdate(
          "UPDATE chats SET updated_at = ?, title = CASE WHEN title = '' AND ? = 'user' "
          'THEN substr(?, 1, 60) ELSE title END WHERE id = ?',
          [t, role, content, chat]);
    });
  }

  final pf = setup['prefs'] as Map?;
  if (pf != null) {
    await prefs.save(ReminderPreferences(
        followUp: pf['follow_up'] as bool? ?? true,
        multiple: pf['multiple'] as bool? ?? true));
  }

  if (setup['pending'] != null) {
    throw StateError('setup.pending requires explicit pending seeding support');
  }

  return EvalFixture(
    db: db,
    path: path,
    tasks: tasks,
    reminders: reminders,
    memory: memory,
    conversations: conversations,
    pending: pending,
    operations: operations,
    prefs: prefs,
    profile: profile,
    scheduler: scheduler,
    refs: refs,
    policyStore: CorePolicyStore(),
  );
}

/// Reopens an existing on-disk database after a simulated process restart.
Future<EvalFixture> reopenEvalFixture({
  required String path,
  required Map<String, Map<String, dynamic>> refs,
  String? notificationIssue,
  CorePolicyStore? policyStore,
}) async {
  final db = await openAppDb(path: path);
  return EvalFixture(
    db: db,
    path: path,
    tasks: TaskRepo(db),
    reminders: ReminderRepo(db),
    memory: MemoryRepo(db),
    conversations: ConversationRepo(db),
    pending: PendingRepo(db),
    operations: OperationJournal(db),
    prefs: ReminderPreferencesRepo(db),
    profile: ProfileRepo(db),
    scheduler: RecordingScheduler(issue: notificationIssue),
    refs: refs,
    // Restart clears conversation-local policy deliberately.
    policyStore: policyStore ?? CorePolicyStore(),
  );
}

LlmEngine evalEngine(
        {required bool native,
        required String dir,
        required DateTime Function() clock}) =>
    native ? HostQwenEngine(dir) : RuleEngine(clock: clock);

class HostQwenEngine extends LlmEngine {
  HostQwenEngine(this.dir);
  final String dir;

  @override
  String get name => 'host-qwen';

  @override
  Future<bool> load() async => true;

  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async {
    final file = File('$dir/prompt.txt')..writeAsStringSync(p.render());
    final grammar = File('$dir/grammar.gbnf')..writeAsStringSync(p.grammar);
    // Mirror LlamaChannelEngine caps: plan 140 / reply 132 / memory 80.
    final tokens = p.kind == PromptKind.action
        ? '140'
        : p.kind == PromptKind.memory
            ? '80'
            : p.kind == PromptKind.plan
                ? '140'
                : '132';
    final r = await Process.run('/tmp/corenyth-native-host', [
      '/tmp/corenyth-Qwen3-0.6B-Q4_0.gguf',
      file.path,
      grammar.path,
      tokens,
    ]);
    if (r.exitCode != 0) throw StateError('native eval exited ${r.exitCode}');
    return r.stdout as String;
  }
}

/// Resolves `$last` against the previous turn's primary typed receipt entity.
/// Writes synthetic refs (`_last_task` / `_last_reminder` / `_last_memory`) into
/// [refs] so the scorer can resolve them by id.
void resolveLastRefs(
  Map<String, dynamic> expect,
  Map<String, Map<String, dynamic>> lastPrimary,
  Map<String, Map<String, dynamic>> refs,
) {
  void walk(dynamic node) {
    if (node is Map) {
      for (final e in node.entries.toList()) {
        if (e.value == '\$last') {
          final key = e.key as String;
          final kind = switch (key) {
            'task' => 'task',
            'reminder' => 'reminder',
            'memory' => 'memory',
            _ => throw StateError('ambiguous \$last on field $key'),
          };
          final hit = lastPrimary[kind];
          if (hit == null) {
            throw StateError('\$last has no prior $kind entity');
          }
          final synthetic = '_entity_${kind}_${hit['id']}';
          refs[synthetic] = {
            'table': hit['table'],
            'id': hit['id'],
          };
          node[key] = synthetic;
        } else {
          walk(e.value);
        }
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item);
      }
    }
  }

  walk(expect);
}

Map<String, Map<String, dynamic>> primaryEntitiesFromTurn({
  required TurnRecord? turn,
  required Map<String, Map<String, dynamic>> refs,
  required Map<String, dynamic> after,
  required Map<String, dynamic> before,
}) {
  final out = <String, Map<String, dynamic>>{};
  if (turn == null) return out;
  for (final r in turn.receipts) {
    if (r.taskIds.isNotEmpty) {
      final id = r.taskIds.first;
      final ref = refs.entries
          .where((e) => e.value['table'] == 'tasks' && e.value['id'] == id)
          .map((e) => e.key)
          .firstOrNull;
      out['task'] = {'table': 'tasks', 'id': id, if (ref != null) 'ref': ref};
      // Bind a synthetic ref for later \$last consumers.
      refs.putIfAbsent('_last_task', () => {'table': 'tasks', 'id': id});
    }
    if (r.reminderIds.isNotEmpty) {
      final id = r.reminderIds.first;
      out['reminder'] = {'table': 'reminders', 'id': id};
      refs['_last_reminder'] = {'table': 'reminders', 'id': id};
    }
  }
  // Memory creates often lack typed receipt ids; detect new active rows.
  final beforeIds = {
    for (final m in before['memories'] as List? ?? []) m['id']
  };
  final created = [
    for (final m in after['memories'] as List? ?? [])
      if (!beforeIds.contains(m['id']) && m['status'] == 'active') m
  ];
  if (created.length == 1) {
    final id = created.single['id'] as int;
    out['memory'] = {'table': 'memories', 'id': id};
    refs['_last_memory'] = {'table': 'memories', 'id': id};
  } else if (created.length > 1) {
    throw StateError('ambiguous memory \$last among ${created.length} rows');
  }
  return out;
}

String defaultInterpreterName() => defaultInterpreter.name;

Map<String, dynamic> runIdentity({
  required String mode,
  required String sourceSha,
}) =>
    {
      'mode': mode,
      'clock': 'fixed local wall time Asia/Kolkata',
      'source_manifest': sourceSha,
      'interpreter': defaultInterpreterName(),
      'prompt_fingerprint': null,
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    };

String readSourceSha() {
  final f = File('eval/results/source-manifest.json');
  if (!f.existsSync()) {
    throw StateError('run eval/source_manifest.py before recording');
  }
  return jsonDecode(f.readAsStringSync())['source_sha256'] as String;
}
