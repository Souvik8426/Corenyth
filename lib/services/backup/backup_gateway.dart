import 'package:flutter/services.dart';

import '../native_bridge.dart';

/// The file-picker and share boundary of the backup feature.
///
/// It exists so the service can be tested without a picker, and so the app
/// can degrade gracefully where no system picker is available.
abstract class BackupFileGateway {
  /// Opens the system file picker and returns the path of a copy of the
  /// chosen backup inside the app's own storage, or null when the user
  /// cancelled. Throws [BackupFileException] when no picker is available or
  /// the file could not be read.
  Future<String?> pickBackupFile();

  /// Hands [path] to the system share sheet so the user can move the backup
  /// to another device. True when the chooser was shown.
  Future<bool> shareBackupFile(String path);
}

/// A picker or share that failed, with a message the user can act on.
class BackupFileException implements Exception {
  final String message;
  const BackupFileException(this.message);

  @override
  String toString() => message;
}

/// The real gateway: the system file picker and share sheet, reached through
/// the `assistant/native` channel.
class NativeBackupFileGateway implements BackupFileGateway {
  const NativeBackupFileGateway();

  @override
  Future<String?> pickBackupFile() async {
    try {
      return await NativeBridge.pickBackupFile();
    } on PlatformException catch (e) {
      throw BackupFileException(nativeBackupError(e).message);
    }
  }

  @override
  Future<bool> shareBackupFile(String path) async {
    try {
      return await NativeBridge.shareBackupFile(path);
    } on PlatformException catch (e) {
      throw BackupFileException(nativeBackupError(e).message);
    }
  }
}

/// A gateway that hands out files the test put there, and records what was
/// shared. Used by the tests; also the fallback where no picker exists.
class FakeBackupFileGateway implements BackupFileGateway {
  /// The file the next pick returns; null = the user cancelled.
  String? nextFile;

  /// The files a pick may return, one per call (the last one repeats).
  final List<String?> files = [];

  /// Paths passed to [shareBackupFile].
  final List<String> shared = [];

  /// When set, sharing fails with this message.
  String? shareError;

  /// When set, picking fails with this message.
  String? pickError;

  int _pickIndex = 0;

  @override
  Future<String?> pickBackupFile() async {
    final error = pickError;
    if (error != null) throw BackupFileException(error);
    if (files.isEmpty) return nextFile;
    final index = _pickIndex < files.length ? _pickIndex++ : files.length - 1;
    return files[index];
  }

  @override
  Future<bool> shareBackupFile(String path) async {
    final error = shareError;
    if (error != null) throw BackupFileException(error);
    shared.add(path);
    return true;
  }
}
