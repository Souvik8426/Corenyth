// Opt-in evaluation: runs synthetic corpus on a fresh production SQLite schema.
// It records actual state; a separate scorer checks expectations. No phone alarms.
import 'dart:convert';
import 'dart:io';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/assistant/turn_contract.dart' show defaultInterpreter;
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CORENYTH_EVAL');
  const native = bool.fromEnvironment('CORENYTH_EVAL_NATIVE');
  const split =
      String.fromEnvironment('CORENYTH_EVAL_SPLIT', defaultValue: 'dev');
  test('record fixed-clock corpus with real SQLite', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('corenyth-eval-');
    final results = <Map<String, dynamic>>[];
    try {
      final rows = File(
              'eval/corpus/single_${split == 'heldout' ? 'heldout' : 'dev'}.jsonl')
          .readAsLinesSync()
          .map((s) => jsonDecode(s) as Map<String, dynamic>);
      for (final c in rows) {
        final db = await openAppDb(path: '${dir.path}/${c['id']}.db');
        final tasks = TaskRepo(db),
            reminders = ReminderRepo(db),
            memory = MemoryRepo(db),
            conv = ConversationRepo(db),
            prefs = ReminderPreferencesRepo(db);
        final refs = <String, Map<String, dynamic>>{};
        final setup = c['setup'] as Map<String, dynamic>? ?? {};
        final now = DateTime.parse(c['now'] as String? ?? '2026-10-19T07:41');
        for (final t in setup['tasks'] as List? ?? []) {
          final v = await tasks.create(t['title'],
              due: t['due'] == null ? null : DateTime.parse(t['due']));
          if (t['done'] == true) await tasks.complete(v.id);
          if (t['awaiting'] != null)
            await tasks.setAwaiting(v.id, t['awaiting']);
          refs[t['ref']] = {'table': 'tasks', 'id': v.id};
        }
        for (final r in setup['reminders'] as List? ?? []) {
          final v = await reminders.create(r['title'], DateTime.parse(r['at']),
              taskId: refs[r['task']]?['id']);
          refs[r['ref']] = {'table': 'reminders', 'id': v.id};
        }
        for (final m in setup['memories'] as List? ?? []) {
          final id =
              await memory.add(m['content'], category: m['category'] ?? 'fact');
          refs[m['ref']] = {'table': 'memories', 'id': id};
        }
        for (final h in setup['history'] as List? ?? []) {
          await conv.add(h['chat'] ?? 'eval', h['role'], h['content']);
        }
        final pf = setup['prefs'] as Map?;
        if (pf != null)
          await prefs.save(ReminderPreferences(
              followUp: pf['follow_up'] ?? true,
              multiple: pf['multiple'] ?? true));
        Future<Map<String, dynamic>> snapshot() async => {
              for (final table in [
                'tasks',
                'reminders',
                'memories',
                'pending_clarifications'
              ])
                table: await db.query(table)
            };
        final session = AssistantSession(
            engine: native ? _HostQwen(dir.path) : RuleEngine(clock: () => now),
            tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
                clock: () => now, preferences: prefs),
            memory: memory,
            profile: ProfileRepo(db),
            taskRepo: tasks,
            conversations: conv,
            pending: PendingRepo(db),
            operations: OperationJournal(db),
            conversationId: 'eval',
            clock: () => now);
        await session.start();
        try {
          final before = await snapshot();
          final timer = Stopwatch()..start();
          final reply =
              await session.handle(c['input'], operationId: 'eval-${c['id']}');
          results.add({
            'id': c['id'],
            'category': c['category'],
            'refs': refs,
            'before': before,
            'after': await snapshot(),
            'reply': reply,
            'diagnostics': session.lastDiagnostics,
            'elapsed_ms': timer.elapsedMilliseconds
          });
        } finally {
          await session.close();
          await db.close();
        }
      }
      Directory('eval/results').createSync(recursive: true);
      File('eval/results/${native ? 'qwen-host' : 'rules'}-$split.json')
          .writeAsStringSync(jsonEncode({
        'mode': native
            ? 'Qwen3-0.6B-Q4_0 host CPU (not Android latency)'
            : 'model-unavailable',
        'clock': 'fixed local wall time Asia/Kolkata',
        'source_manifest': jsonDecode(File('eval/results/source-manifest.json')
            .readAsStringSync())['source_sha256'],
        'interpreter': defaultInterpreter.name,
        'cases': results
      }));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 30)));
}

class _HostQwen extends LlmEngine {
  final String dir;
  _HostQwen(this.dir);
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
    final r = await Process.run('/tmp/corenyth-native-host', [
      '/tmp/corenyth-Qwen3-0.6B-Q4_0.gguf',
      file.path,
      grammar.path,
      p.kind == PromptKind.action
          ? '160'
          : p.kind == PromptKind.memory
              ? '80'
              : '120'
    ]);
    if (r.exitCode != 0) throw StateError('native eval exited ${r.exitCode}');
    return r.stdout as String;
  }
}
