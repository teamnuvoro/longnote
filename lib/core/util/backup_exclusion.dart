import 'package:flutter/services.dart';

/// Keeps a folder out of iCloud device backups (iOS
/// `URLResourceValues.isExcludedFromBackup`; excluding a folder excludes its
/// contents). Native side: `FilesPlugin` in ios/Runner/AppDelegate.swift.
class BackupExclusion {
  const BackupExclusion();
  static const _channel = MethodChannel('longnote/files');

  /// Returns false when not supported (tests, Android) or on error.
  Future<bool> setExcluded(String path, bool excluded) async {
    try {
      return await _channel.invokeMethod<bool>(
              'setExcludedFromBackup', {'path': path, 'excluded': excluded}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
