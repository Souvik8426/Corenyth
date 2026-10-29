// Opt-in multi-turn evaluation: one disposable DB per scenario, shared across
// turns/chats. Records honest failures; does not require the app to pass.
import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/eval_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CORENYTH_EVAL');
  const native = bool.fromEnvironment('CORENYTH_EVAL_NATIVE');

  test('record frozen multi-turn corpus with real SQLite', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('corenyth-multi-');
    final scenarios = <Map<String, dynamic>>[];
    final sourceSha = readSourceSha();
    try {
      final rows = File('eval/corpus/multi_dev.jsonl')
          .readAsLinesSync()
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();
      final seen = <String>{};
      for (final scenario in rows) {
        final id = scenario['id'] as String;
        if (!seen.add(id)) {
          throw StateError('duplicate scenario id $id');
        }
        final setup = Map<String, dynamic>.from(
            scenario['setup'] as Map<String, dynamic>? ?? {});
        final env = Map<String, dynamic>.from(setup['env'] as Map? ?? {});
        setup.remove('env');
        final notificationIssue = env['notifications'] == 'denied'
            ? 'notifications are off'
            : null;
        if (env.containsKey('model') && env['model'] != 'unavailable') {
          throw StateError('${id}: unsupported env.model ${env['model']}');
        }
        for (final key in env.keys) {
          if (!const {'notifications', 'model'}.contains(key)) {
            throw StateError('${id}: unsupported env field $key');
          }
        }

        var clock = DateTime.parse(
            scenario['now'] as String? ?? '2026-10-19T07:41');
        var fixture = await openEvalFixture(
          directory: dir.path,
          name: id,
          setup: setup,
          now: clock,
          notificationIssue: notificationIssue,
        );
        final sessions = <String, AssistantSession>{};
        final turnsOut = <Map<String, dynamic>>[];
        var lastPrimary = <String, Map<String, dynamic>>{};
        Object? scenarioError;

        Future<AssistantSession> sessionFor(String chat) async {
          final existing = sessions[chat];
          if (existing != null) return existing;
          final forceUnavailable = env['model'] == 'unavailable';
          final engine = forceUnavailable || !native
              ? evalEngine(native: false, dir: dir.path, clock: () => clock)
              : evalEngine(native: true, dir: dir.path, clock: () => clock);
          final s = await fixture.openSession(
              chatId: chat, clock: () => clock, engine: engine);
          sessions[chat] = s;
          return s;
        }

        Future<void> closeSessions() async {
          for (final s in sessions.values) {
            await s.close();
          }
          sessions.clear();
        }

        try {
          final turns = scenario['turns'] as List;
          for (var i = 0; i < turns.length; i++) {
            final turn = Map<String, dynamic>.from(turns[i] as Map);
            for (final key in turn.keys) {
              if (!const {
                'input',
                'chat',
                'advance_min',
                'restart_before',
                'cancel',
                'expect',
                'wording'
              }.contains(key)) {
                throw StateError('$id turn$i: unsupported field $key');
              }
            }
            final advance = turn['advance_min'];
            if (advance != null) {
              clock = clock.add(Duration(minutes: advance as int));
            }
            if (turn['restart_before'] == true) {
              await closeSessions();
              await fixture.closeDb();
              fixture = await reopenEvalFixture(
                path: fixture.path,
                refs: fixture.refs,
                notificationIssue: notificationIssue,
              );
            }
            final chat = turn['chat'] as String? ?? 'eval';
            final session = await sessionFor(chat);
            final expect = jsonDecode(jsonEncode(turn['expect']))
                as Map<String, dynamic>;
            if (jsonEncode(expect).contains(r'$last')) {
              resolveLastRefs(expect, lastPrimary, fixture.refs);
            }
            final before = await fixture.snapshot();
            final cancel = turn['cancel'];
            if (cancel != null && cancel != 'before_commit') {
              throw StateError('$id turn$i: unsupported cancel $cancel');
            }
            if (cancel == 'before_commit') {
              session.onBeforeCommit = () {
                session.markCancelled();
              };
            }
            final timer = Stopwatch()..start();
            String reply;
            Object? turnError;
            try {
              reply = await session.handle(turn['input'] as String,
                  operationId: 'eval-$id-$i');
            } catch (e) {
              turnError = e;
              reply = '';
            }
            final after = await fixture.snapshot();
            lastPrimary = primaryEntitiesFromTurn(
              turn: session.lastTurn,
              refs: fixture.refs,
              after: after,
              before: before,
            );
            // Keep stable fixture refs for scored entities created this turn.
            for (final e in lastPrimary.entries) {
              final syn = '_last_${e.key}';
              fixture.refs[syn] = {
                'table': e.value['table'],
                'id': e.value['id'],
              };
            }
            turnsOut.add({
              'index': i,
              'input': turn['input'],
              'chat': chat,
              'expect': expect,
              'refs': Map<String, dynamic>.from(fixture.refs),
              'before': before,
              'after': after,
              'reply': reply,
              'diagnostics': session.lastDiagnostics,
              'scheduler': {
                'scheduled': List.of(fixture.scheduler.scheduled),
                'cancelled': List.of(fixture.scheduler.cancelled),
                'delivery': List.of(fixture.scheduler.deliveryRequests),
                'issue': fixture.scheduler.issue,
              },
              'elapsed_ms': timer.elapsedMilliseconds,
              if (turnError != null) 'error': turnError.toString(),
            });
          }
        } catch (e) {
          scenarioError = e;
        } finally {
          await closeSessions();
          await fixture.closeDb();
        }

        scenarios.add({
          'id': id,
          'category': scenario['category'],
          'turns': turnsOut,
          'final_state': scenario['final_state'],
          'final_snapshot': turnsOut.isEmpty
              ? null
              : turnsOut.last['after'],
          'refs': turnsOut.isEmpty ? {} : turnsOut.last['refs'],
          if (scenarioError != null) 'error': scenarioError.toString(),
        });
      }

      final missing = {
        for (final r in rows) r['id'] as String
      }.difference({for (final s in scenarios) s['id'] as String});
      if (missing.isNotEmpty) {
        throw StateError('missing scenarios: $missing');
      }

      Directory('eval/results').createSync(recursive: true);
      final out = {
        ...runIdentity(
          mode: native
              ? 'Qwen3-0.6B-Q4_0 host CPU multi-turn (not Android latency)'
              : 'model-unavailable multi-turn',
          sourceSha: sourceSha,
        ),
        'corpus': 'multi_dev',
        'scenario_count': scenarios.length,
        'turn_count':
            scenarios.fold<int>(0, (n, s) => n + (s['turns'] as List).length),
        'scenarios': scenarios,
      };
      File('eval/results/${native ? 'qwen-host' : 'rules'}-multi-dev.json')
          .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 45)));
}
