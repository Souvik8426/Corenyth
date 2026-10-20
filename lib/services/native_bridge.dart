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
}
