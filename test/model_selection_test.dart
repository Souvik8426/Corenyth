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
    test('two allowlisted ChatML Qwen3 entries; default is 0.6B', () {
      expect(modelCatalog.map((m) => m.id).toList(),
          [defaultModelId, 'qwen3-1.7b']);
      expect(model06b.expectedBytes, 382156160);
      expect(model17b.expectedBytes, 1056782912);
      expect(model06b.sha256,
          '24ccc1cc08429fadd236268f920e965a376603479ca70f499be8930169c2159b');
      expect(model17b.sha256,
          'c876f159707a4e4f70e045106c69db15bfc935a4981706fd4f65c6e7ea1e81c5');
      for (final m in modelCatalog) {
        expect(m.chatTemplate, 'chatml');
        expect(isAllowlistedModelFile(m.fileName), isTrue);
      }
      expect(modelFileName, model06b.fileName);
      expect(modelBytes, model06b.expectedBytes);
      expect(modelUrl, model06b.url);
    });

    test('rejects arbitrary unsupported GGUF names', () {
      expect(isAllowlistedModelFile('random-model.gguf'), isFalse);
      expect(isAllowlistedModelFile('Qwen2-0.5B-Q4_0.gguf'), isFalse);
      expect(modelByFileName('not-a-model.gguf'), isNull);
      expect(modelById('gpt'), isNull);
    });
  });

  group('checkModel / corrupt size', () {
    test('wrong size is incomplete; exact size ready; missing/noAccess', () {
      final path = p.join(tmp.path, model06b.fileName);
      File(path).writeAsBytesSync(List.filled(4, 0));
      expect(
          checkModel(path,
              granted: true, expectedBytes: model06b.expectedBytes),
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
      File(p.join(tmp.path, model17b.fileName)).writeAsBytesSync([1, 2, 3]);
      expect(checkModelSpec(tmp.path, model17b, granted: true),
          ModelState.incomplete);
    });
  });

  group('selection persistence', () {
    test('missing file → default 0.6B', () {
      expect(sel.readId(), defaultModelId);
      expect(sel.selected.id, defaultModelId);
    });

    test('write/read round-trip; unknown id falls back; reject bad write',
        () async {
      await sel.writeId('qwen3-1.7b');
      expect(sel.readId(), 'qwen3-1.7b');
      await File(p.join(tmp.path, '.selected_model')).writeAsString('bogus');
      expect(sel.readId(), defaultModelId);
      expect(() => sel.writeId('not-in-catalog'), throwsArgumentError);
    });
  });

  group('resolveLoadable fallback', () {
    test('prefers selected when ready; else default; else null', () {
      expect(
          sel.resolveLoadable(tmp.path, isReady: (_) => false), isNull);

      expect(
          sel
              .resolveLoadable(tmp.path,
                  preferredId: 'qwen3-1.7b',
                  isReady: (s) => s.id == defaultModelId)!
              .id,
          defaultModelId);

      expect(
          sel
              .resolveLoadable(tmp.path,
                  preferredId: 'qwen3-1.7b', isReady: (_) => true)!
              .id,
          'qwen3-1.7b');

      File(p.join(tmp.path, '.selected_model')).writeAsStringSync('qwen3-1.7b');
      expect(
          sel
              .resolveLoadable(tmp.path,
                  isReady: (s) => s.id == 'qwen3-1.7b')!
              .id,
          'qwen3-1.7b');
    });
  });

  group('SHA-256 verify', () {
    test('matches real digest, rejects same-size corrupt, caches by size+mtime',
        () async {
      final bytes = utf8.encode('pretend gguf');
      final spec = ModelSpec(
          id: model06b.id,
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
      File(p.join(tmp.path, '.sha256_${model06b.id}')).writeAsStringSync(
          '${st.size}:${st.modified.millisecondsSinceEpoch} ${model06b.sha256}');
      expect(await sel.verify(model06b, path), isTrue);
    });
  });

  test('crash marker survives only an interrupted load', () async {
    expect(await sel.crashedAttempt(), isNull);
    await sel.markAttempt(model17b.id);
    expect((await sel.crashedAttempt())!.id, model17b.id);
    expect(await sel.crashedAttempt(), isNull, reason: 'consumed');
    await sel.markAttempt(model17b.id);
    await sel.clearAttempt();
    expect(await sel.crashedAttempt(), isNull);
  });

  group('AppServices switching (mocked native channel)', () {
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
          p.join(models.path, model06b.fileName))
        ..selection = sel;
    });

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null));

    test('switch 0.6B → 1.7B loads the new path and persists it', () async {
      fakeInstall(sel, models.path, model06b);
      fakeInstall(sel, models.path, model17b);
      expect(await app.ensureModel(), isTrue);
      // Concurrent callers share one load.
      await Future.wait([app.ensureModel(), app.ensureModel()]);
      expect(await app.selectModel(model17b), isTrue);
      expect(loads.last, model17b.fileName, reason: 'no stale cached path');
      expect(app.activeModel!.id, model17b.id);
      expect(sel.readId(), model17b.id);
      expect(app.modelNote.value, isNull);
      expect(await sel.crashedAttempt(), isNull, reason: 'marker cleared');
    });

    test('failed 1.7B load recovers to 0.6B and says so', () async {
      fakeInstall(sel, models.path, model06b);
      fakeInstall(sel, models.path, model17b);
      loadOk = (path) => !path.endsWith(model17b.fileName);
      expect(await app.selectModel(model17b), isFalse);
      expect(loads, [model17b.fileName, model06b.fileName]);
      expect(app.activeModel!.id, defaultModelId);
      expect(app.modelLoad.value.name, 'loaded');
      expect(sel.readId(), defaultModelId);
      expect(app.modelNote.value, contains('default model'));
    });

    test('SHA mismatch never reaches native load; falls back', () async {
      fakeInstall(sel, models.path, model06b);
      fakeInstall(sel, models.path, model17b, corrupt: true);
      expect(await app.selectModel(model17b), isFalse);
      expect(loads, [model06b.fileName]);
      expect(app.modelNote.value, contains('SHA-256'));
    });

    test('default also failing ends on rules (load failed)', () async {
      fakeInstall(sel, models.path, model06b);
      loadOk = (_) => false;
      expect(await app.ensureModel(), isFalse);
      expect(app.modelLoad.value.name, 'failed');
    });

    test('not-installed choice is saved but nothing reloads', () async {
      fakeInstall(sel, models.path, model06b);
      expect(await app.ensureModel(), isTrue);
      expect(await app.selectModel(model17b), isFalse);
      expect(sel.readId(), model17b.id);
      expect(loads, [model06b.fileName]);
      expect(app.activeModel!.id, defaultModelId);
    });

    test('modelState keeps a not-installed selection (download stays offered)', () async {
      const native = MethodChannel('assistant/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native,
              (_) async => {'path': models.path, 'granted': true});
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null));
      fakeInstall(sel, models.path, model06b);
      await sel.writeId(model17b.id);
      expect(await app.modelState(), ModelState.ready);
      expect(app.selectedModel.id, model17b.id);
      expect(app.activeModel!.id, defaultModelId);
    });

    void mockModelsDir() {
      const native = MethodChannel('assistant/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (c) async =>
              c.method == 'modelsDir' ? {'path': models.path, 'granted': true} : null);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null));
    }

    test('re-choosing a saved selection after installing it activates it', () async {
      fakeInstall(sel, models.path, model06b);
      expect(await app.ensureModel(), isTrue);
      expect(await app.selectModel(model17b), isFalse); // not installed yet
      fakeInstall(sel, models.path, model17b);
      expect(await app.selectModel(model17b), isTrue);
      expect(app.activeModel!.id, model17b.id);
    });

    testWidgets('picker: selected-but-inactive installed row can be tapped', (t) async {
      mockModelsDir();
      await t.runAsync(() async {
        fakeInstall(sel, models.path, model06b);
        await app.ensureModel();
        await app.selectModel(model17b); // saved, file missing
        fakeInstall(sel, models.path, model17b); // installed later
      });
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: ModelSetupCard(app)))));
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(app.selectedModel.id, model17b.id);
      expect(app.activeModel!.id, defaultModelId);
      await t.tap(find.text(model17b.label));
      for (var i = 0; i < 20 && (loads.last != model17b.fileName || app.modelLoad.value != ModelLoad.loaded); i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(app.activeModel!.id, model17b.id);
      expect(loads.last, model17b.fileName);
      // Now active and loaded: tapping it again does nothing.
      final n = loads.length;
      await t.tap(find.text(model17b.label));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      expect(loads.length, n);
      await t.pump(const Duration(seconds: 10)); // let the SnackBar time out
    });

    test('concurrent switches serialize', () async {
      fakeInstall(sel, models.path, model06b);
      fakeInstall(sel, models.path, model17b);
      await Future.wait([app.selectModel(model17b), app.selectModel(model06b)]);
      expect(loads, [model17b.fileName, model06b.fileName]);
      expect(app.activeModel!.id, defaultModelId);
      expect(sel.readId(), defaultModelId);
    });
  });
}
