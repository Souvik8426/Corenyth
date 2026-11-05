@Tags(['bench'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/memory_seed.dart';

// Skipped unless MEMORY_BENCH=1 so the default run stays fast.
// Host run: MEMORY_BENCH=1 flutter test --no-pub -t bench test/memory_bench_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  for (final size in memoryBenchSizes) {
    test('host memory retrieval N=$size', skip: Platform.environment['MEMORY_BENCH'] == '1' ? false : 'set MEMORY_BENCH=1', () async {
      final labels = (jsonDecode(await File('test/fixtures/memory_queries.json')
              .readAsString()) as List)
          .cast<Map<String, dynamic>>();
      expect(labels, hasLength(50));
      final dir = await Directory.systemTemp.createTemp('memory-bench-');
      addTearDown(() => dir.delete(recursive: true));
      databaseFactory = databaseFactoryFfi;
      final db = await openAppDb(path: '${dir.path}/bench.db');
      addTearDown(db.close);
      final repo = MemoryRepo(db);
      final corpus = await seedMemoryCorpus(repo, size: size);
      expect(corpus, hasLength(size));
      expect(
          (await db.rawQuery('SELECT COUNT(*) AS total FROM memories'))
              .single['total'],
          size);
      for (final label in labels) {
        final expected = (label['expect_contains'] as List).cast<String>();
        expect(expected, isNotEmpty);
        for (final target in expected) {
          expect(corpus.values.any((text) => text.contains(target)), isTrue,
              reason: 'Missing corpus label: $target');
        }
      }

      final methods = <String, Future<List<Memory>> Function(String)>{
        'search': (query) => repo.search(query, limit: 3),
        'relevantForContext': (query) =>
            repo.relevantForContext(query, limit: 3),
        // important() has no query input; score its global top three against
        // every labelled query, so its quality is comparable to the others.
        'important': (_) => repo.important(limit: 3),
      };
      for (final method in methods.entries) {
        for (var i = 0; i < 10; i++) {
          await method.value(labels[i]['query'] as String);
        }
        final times = <int>[];
        var recall = 0.0;
        var reciprocalRank = 0.0;
        for (var run = 0; run < 200; run++) {
          final label = labels[run % labels.length];
          final timer = Stopwatch()..start();
          final results = await method.value(label['query'] as String);
          timer.stop();
          times.add(timer.elapsedMicroseconds);
          expect(results.length, lessThanOrEqualTo(3));
          if (run < labels.length) {
            final targets = (label['expect_contains'] as List).cast<String>();
            bool matches(Memory memory, String target) =>
                memory.content.contains(target);
            recall += targets
                    .where((target) => results.any((m) => matches(m, target)))
                    .length /
                targets.length;
            final rank = results.indexWhere(
                (memory) => targets.any((target) => matches(memory, target)));
            if (rank >= 0) reciprocalRank += 1 / (rank + 1);
          }
        }
        times.sort();
        // Nearest-rank percentiles: ceil(p * 200) - 1.
        final p50 = times[99] / 1000;
        final p95 = times[189] / 1000;
        // ignore: avoid_print
        print('memory_bench N=$size method=${method.key} runs=200 '
            'queries=${labels.length} p50_ms=${p50.toStringAsFixed(3)} '
            'p95_ms=${p95.toStringAsFixed(3)} '
            'recall@3=${(recall / labels.length).toStringAsFixed(4)} '
            'MRR@3=${(reciprocalRank / labels.length).toStringAsFixed(4)}');
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  }
}
