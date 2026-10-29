// Opt-in evaluation: runs synthetic corpus on a fresh production SQLite schema.
// It records actual state; a separate scorer checks expectations. No phone alarms.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/eval_harness.dart';

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
    final sourceSha = readSourceSha();
    try {
      final rows = File(
              'eval/corpus/single_${split == 'heldout' ? 'heldout' : 'dev'}.jsonl')
          .readAsLinesSync()
          .map((s) => jsonDecode(s) as Map<String, dynamic>);
      for (final c in rows) {
        final setup = Map<String, dynamic>.from(
            c['setup'] as Map<String, dynamic>? ?? {});
        final env = Map<String, dynamic>.from(setup['env'] as Map? ?? {});
        setup.remove('env');
        final notificationIssue = env['notifications'] == 'denied'
            ? 'notifications are off'
            : null;
        for (final key in env.keys) {
          if (!const {'notifications', 'model'}.contains(key)) {
            throw StateError('${c['id']}: unsupported env field $key');
          }
        }
        final now = DateTime.parse(c['now'] as String? ?? '2026-10-19T07:41');
        final fixture = await openEvalFixture(
          directory: dir.path,
          name: c['id'] as String,
          setup: setup,
          now: now,
          notificationIssue: notificationIssue,
        );
        final forceUnavailable = env['model'] == 'unavailable';
        final engine = (forceUnavailable || !native)
            ? evalEngine(native: false, dir: dir.path, clock: () => now)
            : evalEngine(native: true, dir: dir.path, clock: () => now);
        final session = await fixture.openSession(
            chatId: 'eval', clock: () => now, engine: engine);
        try {
          final before = await fixture.snapshot();
          final timer = Stopwatch()..start();
          final reply = await session.handle(c['input'] as String,
              operationId: 'eval-${c['id']}');
          results.add({
            'id': c['id'],
            'category': c['category'],
            'refs': fixture.refs,
            'before': before,
            'after': await fixture.snapshot(),
            'reply': reply,
            'diagnostics': session.lastDiagnostics,
            'scheduler': {
              'scheduled': List.of(fixture.scheduler.scheduled),
              'cancelled': List.of(fixture.scheduler.cancelled),
              'issue': fixture.scheduler.issue,
            },
            'elapsed_ms': timer.elapsedMilliseconds
          });
        } finally {
          await session.close();
          await fixture.closeDb();
        }
      }
      Directory('eval/results').createSync(recursive: true);
      final payload = {
        ...runIdentity(
          mode: native
              ? 'Qwen3-0.6B-Q4_0 host CPU (not Android latency)'
              : 'model-unavailable',
          sourceSha: sourceSha,
        ),
        'cases': results,
      };
      File('eval/results/${native ? 'qwen-host' : 'rules'}-$split.json')
          .writeAsStringSync(jsonEncode(payload));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 30)));
}
