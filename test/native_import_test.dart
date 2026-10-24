import 'dart:async';
import 'dart:io';

import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/model_status.dart';
import 'package:assistant/services/native_bridge.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/v2_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('assistant/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> progress(int bytes) async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
            MethodCall('importProgress', {'bytesCopied': bytes})),
        (_) => done.complete());
    await done.future;
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('import forwards the exact name, progress and final private path',
      () async {
    final updates = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'importModel');
      expect(call.arguments, {'fileName': modelFileName});
      await progress(256);
      await progress(1024);
      return '/private/models/$modelFileName';
    });
    expect(
        await NativeBridge.importModel(modelFileName, onProgress: updates.add),
        '/private/models/$modelFileName');
    expect(updates, [256, 1024]);
    await progress(2048);
    expect(updates, [256, 1024], reason: 'handler removed after completion');
  });

  test('cancellation returns null and a second import can start', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await NativeBridge.importModel(modelFileName), isNull);
    expect(await NativeBridge.importModel(modelFileName), isNull);
  });

  for (final code in ['wrong_file', 'no_picker', 'read_failed', 'no_space']) {
    test('$code propagates and the progress handler is cleaned up', () async {
      final updates = <int>[];
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code);
      });
      await expectLater(
          NativeBridge.importModel(modelFileName, onProgress: updates.add),
          throwsA(
              isA<PlatformException>().having((e) => e.code, 'code', code)));
      await progress(1);
      expect(updates, isEmpty);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await NativeBridge.importModel(modelFileName), isNull);
    });
  }

  test('overlapping imports cannot replace the progress listener', () async {
    final pending = Completer<String?>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    final first = NativeBridge.importModel(modelFileName);
    await expectLater(NativeBridge.importModel(modelFileName),
        throwsA(isA<PlatformException>()));
    pending.complete(null);
    expect(await first, isNull);
  });

  test(
      'app recheck identifies a short imported model; backups use a sibling folder',
      () async {
    final tmp = Directory.systemTemp.createTempSync('private_import');
    final models = Directory(p.join(tmp.path, 'models'))..createSync();
    final db = await openMigratedV2();
    addTearDown(() => tmp.deleteSync(recursive: true));
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'modelsDir'
            ? {'path': models.path, 'granted': true}
            : null);
    final app =
        AppServices(db, NoopScheduler(), p.join(models.path, modelFileName));
    expect(await app.modelState(), ModelState.missing);
    File(app.modelPath).writeAsBytesSync([1, 2, 3]);
    expect(await app.modelState(), ModelState.incomplete);
    expect(await app.backup.backupPath(),
        p.join(tmp.path, 'backups', 'backup.corenyth'));
    final backup = await app.backup.exportBackup();
    expect(File(backup.path).existsSync(), isTrue);
    expect(p.dirname(backup.path), p.join(tmp.path, 'backups'));
    expect(File(app.modelPath).readAsBytesSync(), [1, 2, 3]);
  });
}
