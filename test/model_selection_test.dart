import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistant/main.dart' show ModelSetupCard;
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/model_selection.dart';
import 'package:assistant/services/model_status.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/v2_db.dart';

/// Catalog-sized placeholder (sparse; never read) plus a pre-seeded SHA cache
/// entry, so AppServices sees an installed file without hashing ~1 GB.
void fakeInstall(ModelSelection sel, String dir, ModelSpec m,
    {bool corrupt = false}) {
  final f = File(p.join(dir, m.fileName));
  final raf = f.openSync(mode: FileMode.write)..truncateSync(m.expectedBytes);
  raf.closeSync();
  final st = f.statSync();
  File(p.join(sel.dir, '.sha256_${m.id}')).writeAsStringSync(
      '${st.size}:${st.modified.millisecondsSinceEpoch} '
      '${corrupt ? 'bad' : m.sha256}');
}

void main() {
  late Directory tmp;
  late ModelSelection sel;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('model_sel');
    sel = ModelSelection(tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('catalog', () {
    test('the fine-tuned Corenyth 0.6B is the default allowlisted model', () {
      expect(modelCatalog.map((m) => m.id).toList(),
          [defaultModelId, qwen3Model.id, gemma4Model.id]);
      expect(modelCatalog.first, corenythModel);
      expect(corenythModel.id, 'corenyth-0.6b-tuned');
      expect(corenythModel.expectedBytes, 381566592);
      expect(corenythModel.sha256,
          'f2086705f885560e76ceb8e48b25bc3a07fad3f0f429f5202efd6dd8bfca69ee');
      expect(corenythModel.url,
          startsWith('https://github.com/Souvik8426/Corenyth/releases/download/'));
      expect(corenythModel.url, endsWith('/${corenythModel.fileName}'));
      expect(corenythModel.chatTemplate, 'chatml');
      expect(isAllowlistedModelFile(corenythModel.fileName), isTrue);
      expect(modelFileName, corenythModel.fileName);
      expect(modelBytes, corenythModel.expectedBytes);
      expect(modelUrl, corenythModel.url);
    });

    test('rejects the stock Qwen3 files and arbitrary GGUF names', () {
      expect(isAllowlistedModelFile('Qwen3-0.6B-Q4_0.gguf'), isFalse);
      expect(isAllowlistedModelFile('Qwen3-1.7B-Q4_0.gguf'), isFalse);
      expect(isAllowlistedModelFile('random-model.gguf'), isFalse);
      expect(modelById('qwen3-0.6b'), isNull);
      expect(modelById('qwen3-1.7b'), isNull);
    });
  });

  group('checkModel / corrupt size', () {
    test('wrong size is incomplete; exact size ready; missing/noAccess', () {
      final path = p.join(tmp.path, corenythModel.fileName);
      File(path).writeAsBytesSync(List.filled(4, 0));
      expect(
          checkModel(path,
              granted: true, expectedBytes: corenythModel.expectedBytes),
          ModelState.incomplete);
      // Same-size "corrupt" still reports ready: size only; see verify tests.
      File(path).writeAsBytesSync(List.filled(8, 1));
      expect(checkModel(path, granted: true, expectedBytes: 8), ModelState.ready);
      expect(checkModel(path, granted: false), ModelState.noAccess);
      expect(
          checkModel(p.join(tmp.path, 'missing.gguf'),
              granted: true, expectedBytes: 4),
          ModelState.missing);
    });

    test('checkModelSpec uses catalog bytes', () {
      File(p.join(tmp.path, corenythModel.fileName)).writeAsBytesSync([1, 2, 3]);
      expect(checkModelSpec(tmp.path, corenythModel, granted: true),
          ModelState.incomplete);
    });
  });

  group('selection persistence', () {
    test('missing file → the fine-tuned default', () {
      expect(sel.readId(), defaultModelId);
      expect(sel.selected.id, defaultModelId);
    });

    test('a saved stock model choice falls back; bad writes are rejected',
        () async {
      await File(p.join(tmp.path, '.selected_model')).writeAsString('qwen3-1.7b');
      expect(sel.readId(), defaultModelId);
      await sel.writeId(defaultModelId);
      expect(sel.readId(), defaultModelId);
      expect(() => sel.writeId('qwen3-0.6b'), throwsArgumentError);
    });

    test('resolveLoadable: the model when ready, else null', () {
      expect(sel.resolveLoadable(tmp.path, isReady: (_) => false), isNull);
      expect(sel.resolveLoadable(tmp.path, isReady: (_) => true)!.id,
          defaultModelId);
    });
  });

  group('SHA-256 verify', () {
    test('matches real digest, rejects same-size corrupt, caches by size+mtime',
        () async {
      final bytes = utf8.encode('pretend gguf');
      final spec = ModelSpec(
          id: corenythModel.id,
          fileName: 'x.gguf',
          url: '',
          expectedBytes: bytes.length,
          label: 'x',
          sha256: sha256.convert(bytes).toString());
      final path = p.join(tmp.path, 'x.gguf');
      File(path).writeAsBytesSync(bytes);
      expect(await sel.verify(spec, path), isTrue);

      // Same size, different bytes, new mtime → re-hashed and rejected.
      File(path).writeAsBytesSync(utf8.encode('corrupt gguf'));
      File(path).setLastModifiedSync(DateTime(2030));
      expect(checkModel(path, granted: true, expectedBytes: bytes.length),
          ModelState.ready);
      expect(await sel.verify(spec, path), isFalse);

      expect(await sel.verify(spec, p.join(tmp.path, 'none.gguf')), isFalse);
    });

    test('unchanged size+mtime uses the cached digest', () async {
      final path = p.join(tmp.path, 'y.gguf');
      File(path).writeAsStringSync('abc');
      final st = File(path).statSync();
      File(p.join(tmp.path, '.sha256_${corenythModel.id}')).writeAsStringSync(
          '${st.size}:${st.modified.millisecondsSinceEpoch} ${corenythModel.sha256}');
      expect(await sel.verify(corenythModel, path), isTrue);
    });
  });

  test('crash marker survives only an interrupted load', () async {
    expect(await sel.crashedAttempt(), isNull);
    await sel.markAttempt(corenythModel.id);
    expect((await sel.crashedAttempt())!.id, corenythModel.id);
    expect(await sel.crashedAttempt(), isNull, reason: 'consumed');
    await sel.markAttempt(corenythModel.id);
    await sel.clearAttempt();
    expect(await sel.crashedAttempt(), isNull);
  });

  group('AppServices loading (mocked native channel)', () {
    const ch = MethodChannel('assistant/llm');
    late List<String> loads;
    late bool Function(String path) loadOk;
    late Directory models;
    late AppServices app;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      loads = [];
      loadOk = (_) => true;
      models = Directory(p.join(tmp.path, 'models'))..createSync();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async {
        if (c.method != 'load') return null;
        final path = (c.arguments as Map)['path'] as String;
        loads.add(p.basename(path));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return loadOk(path);
      });
      app = AppServices(await openMigratedV2(), NoopScheduler(),
          p.join(models.path, corenythModel.fileName))
        ..selection = sel;
    });

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null));

    test('loads the fine-tuned model; concurrent callers share one load',
        () async {
      fakeInstall(sel, models.path, corenythModel);
      expect(await app.ensureModel(), isTrue);
      await Future.wait([app.ensureModel(), app.ensureModel()]);
      expect(loads.first, corenythModel.fileName);
      expect(app.activeModel!.id, defaultModelId);
      expect(await sel.crashedAttempt(), isNull, reason: 'marker cleared');
    });

    test('SHA mismatch never reaches native load; rules take over', () async {
      fakeInstall(sel, models.path, corenythModel, corrupt: true);
      expect(await app.ensureModel(), isFalse);
      expect(loads, isEmpty);
      expect(app.modelLoad.value.name, 'failed');
    });

    test('a failing load ends on rules (load failed)', () async {
      fakeInstall(sel, models.path, corenythModel);
      loadOk = (_) => false;
      expect(await app.ensureModel(), isFalse);
      expect(app.modelLoad.value.name, 'failed');
    });

    testWidgets('setup imports with progress then reports an incomplete file',
        (t) async {
      const native = MethodChannel('assistant/native');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final imported = Completer<String?>();
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'modelsDir') return {'path': models.path, 'granted': true};
        if (call.method == 'importModel') {
          expect(call.arguments, {'fileName': corenythModel.fileName});
          return imported.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelSetupCard(app)))));
      await t.pumpAndSettle();
      expect(find.text('Download in browser'), findsOneWidget);
      expect(find.textContaining('Documents'), findsNothing);
      await t.tap(find.text('Choose the downloaded file'));
      await t.pump();
      final reply = Completer<void>();
      await messenger.handlePlatformMessage(native.name,
          const StandardMethodCodec().encodeMethodCall(
              const MethodCall('importProgress', {'bytesCopied': 1024 * 1024})),
          (_) => reply.complete());
      await reply.future;
      await t.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Copying: 1.0 MB'), findsOneWidget);
      File(p.join(models.path, corenythModel.fileName)).writeAsBytesSync([1, 2]);
      imported.complete(p.join(models.path, corenythModel.fileName));
      await t.pumpAndSettle();
      expect(find.textContaining('is incomplete'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(loads, isEmpty, reason: 'incomplete files must never load');
    });

    testWidgets('a complete import automatically retries a failed model load',
        (t) async {
      const native = MethodChannel('assistant/native');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'modelsDir') return {'path': models.path, 'granted': true};
        if (call.method == 'importModel') {
          fakeInstall(sel, models.path, corenythModel);
          return p.join(models.path, corenythModel.fileName);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      app.modelLoad.value = ModelLoad.failed;
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelSetupCard(app)))));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose the downloaded file'));
      // Hash cache and crash marker use real file I/O, outside the widget clock.
      for (var i = 0; i < 30; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 20));
        if (app.modelLoad.value == ModelLoad.loaded) break;
      }
      expect(loads, [corenythModel.fileName]);
      expect(app.modelLoad.value, ModelLoad.loaded);
      expect(find.text('The assistant is now using the local model.'), findsOneWidget);
    });

    testWidgets('setup explains a wrong filename and allows retry', (t) async {
      const native = MethodChannel('assistant/native');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async {
        if (call.method == 'modelsDir') return {'path': models.path, 'granted': true};
        if (call.method == 'importModel') throw PlatformException(code: 'wrong_file');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(native, null));
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelSetupCard(app)))));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose the downloaded file'));
      await t.pumpAndSettle();
      expect(find.textContaining('The selected file has a different name'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
      expect(loads, isEmpty);
    });

    testWidgets('details list the catalog, recommend the trained model, no download button', (t) async {
      const native = MethodChannel('assistant/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (c) async =>
              c.method == 'modelsDir' ? {'path': models.path, 'granted': true} : null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null));
      await t.runAsync(() async {
        fakeInstall(sel, models.path, corenythModel);
        await app.ensureModel();
      });
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelSetupCard(app)))));
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(find.text('${corenythModel.label} · Recommended'), findsOneWidget);
      expect(find.text(qwen3Model.label), findsOneWidget);
      expect(find.textContaining('Qwen3 1.7B'), findsNothing);
      expect(find.textContaining('Download'), findsNothing);
    });
  });
}
