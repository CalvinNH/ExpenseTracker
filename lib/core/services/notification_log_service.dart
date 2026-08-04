import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Debug-build-only file logger for the notification ingestion pipeline.
///
/// Release builds never create or append this file. Debug logs contain
/// operational metadata only and are auto-rotated to [_maxEntries] entries.
class NotificationLogService {
  NotificationLogService._();

  static final NotificationLogService instance = NotificationLogService._();

  static const String _fileName = 'notification_debug.log';

  /// Maximum number of log entries before the file is trimmed.
  static const int _maxEntries = 500;

  File? _logFile;
  bool _initialized = false;

  Future<File> get _file async {
    if (_logFile != null) return _logFile!;
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/$_fileName');
    return _logFile!;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final file = await _file;
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString(
        '=== Notification Debug Log ===\n'
        'Created: ${DateTime.now().toIso8601String()}\n\n',
      );
    }
    _initialized = true;
  }

  /// Append a structured log entry.
  Future<void> log(String tag, String message) async {
    if (kReleaseMode) return;
    try {
      await _ensureInitialized();
      final file = await _file;
      final timestamp = DateTime.now().toIso8601String();
      final entry = '[$timestamp] [$tag] $message\n';
      await file.writeAsString(entry, mode: FileMode.append);

      // Rotate if needed (check periodically, not every write)
      await _rotateIfNeeded(file);
    } catch (_) {
      // Logging must never crash the host code path.
    }
  }

  /// Log source metadata. Raw notification text is never written in release.
  Future<void> logNotificationReceived({
    required String packageName,
    required bool hasRemoved,
    int? notificationId,
    int? postedAtMillis,
  }) async {
    await log(
      'RECEIVED',
      'pkg=$packageName | removed=$hasRemoved | '
          'notificationId=${notificationId ?? '-'} | '
          'postedAtMillis=${postedAtMillis ?? '-'}',
    );
  }

  /// Log an error at any stage.
  Future<void> logError(String stage, String _) async {
    // Exception messages are deliberately discarded: plugin/database errors
    // can embed arguments supplied by a notification.
    await log('ERROR', '$stage | failure');
  }

  /// Trim the log file to keep only the last [_maxEntries] lines.
  Future<void> _rotateIfNeeded(File file) async {
    try {
      final lines = await file.readAsLines();
      if (lines.length > _maxEntries + 50) {
        // Keep a header + the last _maxEntries lines
        final trimmed = [
          '=== Notification Debug Log (rotated ${DateTime.now().toIso8601String()}) ===',
          '',
          ...lines.sublist(lines.length - _maxEntries),
        ];
        await file.writeAsString('${trimmed.join('\n')}\n');
      }
    } catch (_) {}
  }

  /// Read the full log contents.
  Future<String> readLog() async {
    if (kReleaseMode) return '(Logging disabled in release builds)';
    try {
      await _ensureInitialized();
      final file = await _file;
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {}
    return '(No log data available)';
  }

  /// Deletes logs left by older versions when running a release build.
  Future<void> enforcePrivacyPolicy() async {
    if (!kReleaseMode) return;
    try {
      final file = await _file;
      if (await file.exists()) await file.delete();
      _initialized = false;
      _logFile = null;
    } catch (_) {}
  }

  /// Clear the log file.
  Future<void> clearLog() async {
    if (kReleaseMode) {
      await enforcePrivacyPolicy();
      return;
    }
    try {
      final file = await _file;
      if (await file.exists()) {
        await file.writeAsString(
          '=== Notification Debug Log (cleared ${DateTime.now().toIso8601String()}) ===\n\n',
        );
      }
    } catch (_) {}
  }
}
