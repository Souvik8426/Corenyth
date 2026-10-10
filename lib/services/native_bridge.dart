import 'package:flutter/services.dart';

/// Android-side helpers (implemented in MainActivity.kt).
class NativeBridge {
  static const _ch = MethodChannel('assistant/native');

  /// Re-render the home-screen widget (it reads the same SQLite file).
  static Future<void> refreshWidget() async {
    try {
      await _ch.invokeMethod('refreshWidget');
    } on MissingPluginException {
      // not on Android
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

  /// Close the translucent voice activity without killing the app process.
  static Future<void> closeActivity() => SystemNavigator.pop();
}
