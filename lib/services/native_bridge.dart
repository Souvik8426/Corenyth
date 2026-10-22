import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android-side helpers (implemented in MainActivity.kt).
class NativeBridge {
  static const _ch = MethodChannel('assistant/native');

  /// Re-render the home-screen widget (it reads the same SQLite file).
  /// Best effort, never throws: callers run it after a committed write, and a
  /// failure here must not look like the write failed (which invites a retry).
  static Future<void> refreshWidget() async {
    try {
      await _ch.invokeMethod('refreshWidget');
    } on MissingPluginException {
      // not on Android
    } catch (e) {
      debugPrint('widget refresh failed: $e');
    }
  }

  /// Asks the launcher to place the Corenyth widget on the home screen.
  /// False when it can't (older Android, some launchers, not on Android):
  /// the user then adds it from the home screen's widget picker.
  static Future<bool> pinWidget({bool compact = false}) async {
    try {
      return await _ch.invokeMethod<bool>('pinWidget', {'compact': compact}) ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('widget pin failed: $e');
      return false;
    }
  }

  /// Public `Documents/localmodels`. Creates it when storage access is granted, so
  /// calling this on every boot also re-creates it if the user deleted it.
  static Future<({String path, bool granted})> modelsDir() async {
    final m = (await _ch.invokeMapMethod<String, Object?>('modelsDir'))!;
    return (path: m['path'] as String, granted: m['granted'] as bool);
  }

  /// Opens the system screen / prompt for storage access (Android 11+: "All files access").
  static Future<void> requestStorageAccess() => _ch.invokeMethod('requestStorageAccess');

  /// Hands an https URL to the user's browser (the app itself has no INTERNET permission).
  static Future<void> openUrl(String url) => _ch.invokeMethod('openUrl', url);

  /// Address the feedback mail goes to (fixed natively too).
  static const feedbackEmail = 'souvikdas8426@gmail.com';

  /// Opens the user's mail app with a feedback draft to [feedbackEmail]; the
  /// draft notes app version, Android version, phone and [model]. Nothing is
  /// sent until the user sends it. Throws PlatformException `no_mail_app`.
  static Future<void> sendFeedback({String? model}) => _ch.invokeMethod(
      'sendFeedback', {'subject': 'Corenyth alpha feedback', 'model': model});

  /// Opens a chat link (https with a host only; re-validated natively). Throws
  /// PlatformException when rejected or no browser is installed.
  static Future<void> openExternalLink(String url) =>
      _ch.invokeMethod('openExternalLink', url);

  /// Close the translucent voice activity without killing the app process.
  static Future<void> closeActivity() => SystemNavigator.pop();

  /// Opens the system file picker for a Corenyth backup.
  ///
  /// Returns the absolute path of a copy of the chosen file inside the app's
  /// own cache (the original is never touched), or null when the user
  /// cancelled. Throws [PlatformException] with code `no_picker` when no
  /// picker is available and `read_failed` when the file could not be read.
  static Future<String?> pickBackupFile() async {
    try {
      return await _ch.invokeMethod<String?>('pickBackup');
    } on MissingPluginException {
      return null;
    }
  }

  /// Hands the backup at [path] to the system share sheet, so the user can
  /// move it to another device. Throws [PlatformException] with code
  /// `no_app` when nothing can receive it and `bad_path` when the file is
  /// gone.
  static Future<bool> shareBackupFile(String path) async {
    try {
      return await _ch.invokeMethod<bool>('shareBackup', {'path': path}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// A picker or share that failed on the native side.
class NativeBackupException implements Exception {
  final String code;
  final String message;
  const NativeBackupException(this.code, this.message);

  @override
  String toString() => message;
}

/// The native failure codes the backup picker and share sheet report, turned
/// into messages the user can act on.
NativeBackupException nativeBackupError(PlatformException e) =>
    NativeBackupException(
        e.code,
        switch (e.code) {
          'no_picker' => 'No file picker is available on this device.',
          'read_failed' => 'That file could not be read.',
          'no_app' => 'No app on this device can receive the backup.',
          'bad_path' => 'The backup file is gone.',
          _ => 'The backup could not be opened.',
        });
