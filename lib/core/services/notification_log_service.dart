import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Persistent file-based logger for the notification ingestion pipeline.
///
/// Every notification received by the app is logged with its raw data,
/// filter decisions, parser results, and database outcomes. Logs are
/// stored in `notification_debug.log` inside the app's documents
/// directory and auto-rotated to keep at most [_maxEntries] entries.
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

  /// Log a filter decision (pass / drop with reason).
  Future<void> logFilterDecision({
    required String packageName,
    required bool passed,
    String? reason,
  }) async {
    final status = passed ? 'PASS' : 'DROP';
    await log(
      'FILTER',
      '$status pkg=$packageName${reason != null ? ' | reason=$reason' : ''}',
    );
  }

  /// Log the parser result.
  Future<void> logParseResult({
    required bool success,
    String? parsedSummary,
    String? rawInput,
  }) async {
    if (success) {
      await log('PARSER', 'OK | $parsedSummary');
    } else {
      await log(
        'PARSER',
        kReleaseMode
            ? 'FAIL | code=parser_no_match'
            : 'FAIL | input="$rawInput"',
      );
    }
  }

  /// Log the duplicate check result.
  Future<void> logDuplicateCheck({
    required bool isDuplicate,
    String? details,
  }) async {
    await log(
      'DEDUP',
      'duplicate=$isDuplicate${details != null ? ' | $details' : ''}',
    );
  }

  /// Log a successful database write.
  Future<void> logDatabaseWrite({
    required int transactionId,
    required String accountName,
  }) async {
    await log('DB_WRITE', 'OK | txnId=$transactionId | account=$accountName');
  }

  /// Log an error at any stage.
  Future<void> logError(String stage, String error) async {
    await log('ERROR', '$stage | $error');
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
    try {
      await _ensureInitialized();
      final file = await _file;
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {}
    return '(No log data available)';
  }

  /// Share the log file via the system share sheet.
  Future<void> exportLog() async {
    await _ensureInitialized();
    final file = await _file;
    if (await file.exists()) {
      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Expense Tracker — Notification Debug Log');
    }
  }

  /// Clear the log file.
  Future<void> clearLog() async {
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
