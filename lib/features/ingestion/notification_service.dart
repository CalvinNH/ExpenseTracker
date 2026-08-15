import 'dart:async';
import 'dart:ui';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/services/notification_log_service.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum CaptureBatchFailureStage { processing, acknowledgement }

class CaptureBatchDrainOutcome {
  const CaptureBatchDrainOutcome._({
    required this.completed,
    required this.processedCount,
    required this.acknowledgedCount,
    this.failureStage,
    this.error,
    this.stackTrace,
  });

  const CaptureBatchDrainOutcome.completed({
    required int processedCount,
    required int acknowledgedCount,
  }) : this._(
         completed: true,
         processedCount: processedCount,
         acknowledgedCount: acknowledgedCount,
       );

  const CaptureBatchDrainOutcome.failed({
    required int processedCount,
    required int acknowledgedCount,
    required CaptureBatchFailureStage failureStage,
    required Object error,
    required StackTrace stackTrace,
  }) : this._(
         completed: false,
         processedCount: processedCount,
         acknowledgedCount: acknowledgedCount,
         failureStage: failureStage,
         error: error,
         stackTrace: stackTrace,
       );

  final bool completed;
  final int processedCount;
  final int acknowledgedCount;
  final CaptureBatchFailureStage? failureStage;
  final Object? error;
  final StackTrace? stackTrace;
}

class NativeHeadlessDrainState {
  const NativeHeadlessDrainState({
    required this.outstandingCount,
    this.nextEligibleAtMillis,
  }) : assert(outstandingCount >= 0);

  final int outstandingCount;
  final int? nextEligibleAtMillis;
}

enum HeadlessDrainStatus { drained, retry, moreWork }

class HeadlessDrainOutcome {
  const HeadlessDrainOutcome({
    required this.status,
    required this.processedCount,
    required this.acknowledgedCount,
    required this.outstandingCount,
    this.nextEligibleAtMillis,
    this.failureCode,
  });

  final HeadlessDrainStatus status;
  final int processedCount;
  final int acknowledgedCount;
  final int outstandingCount;
  final int? nextEligibleAtMillis;
  final String? failureCode;

  Map<String, Object?> toCompletionMap() => {
    'status': status.name,
    'outstandingCount': outstandingCount,
    if (nextEligibleAtMillis != null)
      'nextEligibleAtMillis': nextEligibleAtMillis,
    if (failureCode != null) 'code': failureCode,
  };
}

/// Runs one headless worker contract and reports completion exactly once. Any
/// uncaught Dart failure is converted to a retry without exposing private data.
@visibleForTesting
Future<HeadlessDrainOutcome> runHeadlessWorkerTask({
  required Future<HeadlessDrainOutcome> Function() drain,
  required Future<void> Function(Map<String, Object?> result) complete,
}) async {
  late final HeadlessDrainOutcome outcome;
  try {
    outcome = await drain();
  } catch (_) {
    outcome = const HeadlessDrainOutcome(
      status: HeadlessDrainStatus.retry,
      processedCount: 0,
      acknowledgedCount: 0,
      outstandingCount: 0,
      failureCode: 'worker',
    );
  }
  await complete(outcome.toCompletionMap());
  return outcome;
}

class NativeAcknowledgementCountException implements Exception {
  const NativeAcknowledgementCountException({
    required this.expected,
    required this.actual,
  });

  final int expected;
  final int actual;

  @override
  String toString() =>
      'Native acknowledgement count mismatch: expected $expected, got $actual.';
}

/// Processes one native lease batch. If processing or acknowledgement fails,
/// the failed capture and every capture after it are released immediately.
@visibleForTesting
Future<CaptureBatchDrainOutcome> drainClaimedCaptureBatch<T>({
  required List<T> captures,
  required String Function(T capture) inboxIdOf,
  required String Function(T capture) leaseTokenOf,
  required Future<void> Function(T capture) process,
  required Future<int> Function(String leaseToken, List<String> ids)
  acknowledge,
  required Future<void> Function(String leaseToken, List<String> ids) release,
  required Future<void> Function(Object error, StackTrace stackTrace) onError,
}) async {
  var processedCount = 0;
  var acknowledgedCount = 0;
  for (var index = 0; index < captures.length; index++) {
    final capture = captures[index];
    var failureStage = CaptureBatchFailureStage.processing;
    try {
      await process(capture);
      processedCount++;
      failureStage = CaptureBatchFailureStage.acknowledgement;
      final ids = [inboxIdOf(capture)];
      final count = await acknowledge(leaseTokenOf(capture), ids);
      if (count != ids.length) {
        throw NativeAcknowledgementCountException(
          expected: ids.length,
          actual: count,
        );
      }
      acknowledgedCount += count;
    } catch (error, stackTrace) {
      final remainingByLease = <String, List<String>>{};
      for (final remaining in captures.skip(index)) {
        remainingByLease
            .putIfAbsent(leaseTokenOf(remaining), () => <String>[])
            .add(inboxIdOf(remaining));
      }

      final releaseFailures = <(Object, StackTrace)>[];
      for (final entry in remainingByLease.entries) {
        try {
          await release(entry.key, entry.value);
        } catch (releaseError, releaseStackTrace) {
          releaseFailures.add((releaseError, releaseStackTrace));
        }
      }
      try {
        await onError(error, stackTrace);
      } catch (_) {
        // Diagnostics are best effort and must not hide the ingestion failure.
      }
      for (final failure in releaseFailures) {
        try {
          await onError(failure.$1, failure.$2);
        } catch (_) {
          // The original retryable failure remains authoritative.
        }
      }
      return CaptureBatchDrainOutcome.failed(
        processedCount: processedCount,
        acknowledgedCount: acknowledgedCount,
        failureStage: failureStage,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  return CaptureBatchDrainOutcome.completed(
    processedCount: processedCount,
    acknowledgedCount: acknowledgedCount,
  );
}

/// Bounded, UI-free drain loop shared by the Android background isolate and
/// deterministic tests. Native state is checked before declaring completion so
/// an empty claim caused by retry delay or another isolate never loses work.
@visibleForTesting
Future<HeadlessDrainOutcome> drainHeadlessCaptureInbox<T>({
  required Duration budget,
  required int batchLimit,
  required int maxCaptures,
  required bool Function() budgetExpired,
  required Future<List<T>> Function(int limit) claim,
  required String Function(T capture) inboxIdOf,
  required String Function(T capture) leaseTokenOf,
  required Future<void> Function(T capture) process,
  required Future<int> Function(String leaseToken, List<String> ids)
  acknowledge,
  required Future<void> Function(String leaseToken, List<String> ids) release,
  required Future<NativeHeadlessDrainState> Function() readState,
  required Future<void> Function(Object error, StackTrace stackTrace) onError,
}) async {
  if (budget <= Duration.zero || batchLimit <= 0 || maxCaptures <= 0) {
    throw ArgumentError('Headless drain bounds must be positive.');
  }

  var processedCount = 0;
  var acknowledgedCount = 0;

  Future<HeadlessDrainOutcome> finishFromState() async {
    try {
      final state = await readState();
      return HeadlessDrainOutcome(
        status: state.outstandingCount == 0
            ? HeadlessDrainStatus.drained
            : HeadlessDrainStatus.moreWork,
        processedCount: processedCount,
        acknowledgedCount: acknowledgedCount,
        outstandingCount: state.outstandingCount,
        nextEligibleAtMillis: state.nextEligibleAtMillis,
      );
    } catch (error, stackTrace) {
      try {
        await onError(error, stackTrace);
      } catch (_) {}
      return HeadlessDrainOutcome(
        status: HeadlessDrainStatus.retry,
        processedCount: processedCount,
        acknowledgedCount: acknowledgedCount,
        outstandingCount: 0,
        failureCode: 'native_state',
      );
    }
  }

  while (!budgetExpired() && processedCount < maxCaptures) {
    final remaining = maxCaptures - processedCount;
    final limit = remaining < batchLimit ? remaining : batchLimit;
    late final List<T> captures;
    try {
      captures = await claim(limit);
    } catch (error, stackTrace) {
      try {
        await onError(error, stackTrace);
      } catch (_) {}
      return HeadlessDrainOutcome(
        status: HeadlessDrainStatus.retry,
        processedCount: processedCount,
        acknowledgedCount: acknowledgedCount,
        outstandingCount: 0,
        failureCode: 'native_claim',
      );
    }

    if (captures.isEmpty) return finishFromState();
    final batch = await drainClaimedCaptureBatch<T>(
      captures: captures,
      inboxIdOf: inboxIdOf,
      leaseTokenOf: leaseTokenOf,
      process: process,
      acknowledge: acknowledge,
      release: release,
      onError: onError,
    );
    processedCount += batch.processedCount;
    acknowledgedCount += batch.acknowledgedCount;
    if (!batch.completed) {
      return HeadlessDrainOutcome(
        status: HeadlessDrainStatus.retry,
        processedCount: processedCount,
        acknowledgedCount: acknowledgedCount,
        outstandingCount: 1,
        failureCode:
            batch.failureStage == CaptureBatchFailureStage.acknowledgement
            ? 'native_ack'
            : 'processing',
      );
    }
  }

  return finishFromState();
}

@visibleForTesting
void dispatchIngestionResult({
  required IngestionResult result,
  required void Function() onTransactionIngested,
  required void Function() onReviewInboxChanged,
}) {
  if (result.isReceiptReplay) return;
  if (result.disposition == IngestionDisposition.posted) {
    onTransactionIngested();
  } else if (result.disposition == IngestionDisposition.retained ||
      result.disposition == IngestionDisposition.provisional) {
    onReviewInboxChanged();
  }
}

@visibleForTesting
DateTime captureIngestedAt(int capturedAtMillis, DateTime now) {
  if (capturedAtMillis <= 0) return now;
  final capturedAt = DateTime.fromMillisecondsSinceEpoch(
    capturedAtMillis,
    isUtc: now.isUtc,
  );
  if (capturedAt.isAfter(now.add(const Duration(minutes: 5)))) return now;
  return capturedAt;
}

/// Drains the app-owned native capture inbox. Android persists every eligible
/// notification before this service is involved, so the Flutter event stream
/// is only a wake-up signal and never the source of truth.
class NotificationService {
  static bool _isInitialized = false;
  static Future<void>? _initialization;
  static NotificationIngestionProcessor _processor =
      NotificationIngestionProcessor();
  static Future<void> _ingestionTail = Future<void>.value();
  static StreamSubscription<dynamic>? _inboxWakeSubscription;

  static const MethodChannel _captureChannel = MethodChannel(
    'expense_tracker/notification_capture',
  );
  static const MethodChannel _backgroundControlChannel = MethodChannel(
    'expense_tracker/notification_background_control',
  );
  static const EventChannel _captureEvents = EventChannel(
    'expense_tracker/notification_capture_events',
  );

  static final StreamController<void> _onTransactionIngested =
      StreamController<void>.broadcast();
  static Stream<void> get onTransactionIngested =>
      _onTransactionIngested.stream;
  static final StreamController<void> _onReviewInboxChanged =
      StreamController<void>.broadcast();
  static Stream<void> get onReviewInboxChanged => _onReviewInboxChanged.stream;

  static final _nlog = NotificationLogService.instance;

  static void notifyTransactionIngested() => _onTransactionIngested.add(null);

  static void notifyReviewInboxChanged() => _onReviewInboxChanged.add(null);

  static String extractBankCode(String bankName) {
    final clean = bankName.toLowerCase();
    for (final code in [
      'hdfc',
      'sbi',
      'icici',
      'axis',
      'kotak',
      'pnb',
      'bob',
      'yes',
      'citi',
      'hsbc',
      'paytm',
      'gpay',
    ]) {
      if (clean.contains(code)) return code;
    }
    return clean.split(' ').first;
  }

  static Future<bool> hasNotificationPermission() async {
    try {
      return await _captureChannel.invokeMethod<bool>(
            'hasNotificationAccess',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's Notification Access settings. The caller must re-check
  /// [hasNotificationPermission] after the user returns from Settings.
  static Future<void> requestNotificationPermission() async {
    try {
      await _captureChannel.invokeMethod<bool>(
        'openNotificationListenerSettings',
      );
    } on MissingPluginException {
      // Non-Android platforms and widget tests do not have a native listener.
    }
  }

  static Future<bool> isServiceConnected() async {
    try {
      return await _captureChannel.invokeMethod<bool>('isListenerConnected') ??
          false;
    } on MissingPluginException {
      return false;
    } catch (error) {
      await _nlog.logError('STATUS_CHECK', '$error');
      return false;
    }
  }

  static Future<bool> reconnectService() async {
    try {
      final requested =
          await _captureChannel.invokeMethod<bool>('requestListenerRebind') ??
          false;
      if (!requested) return false;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      return await isServiceConnected();
    } on MissingPluginException {
      return false;
    } catch (error) {
      await _nlog.logError('RECONNECT', '$error');
      return false;
    }
  }

  /// A value-only health snapshot suitable for settings and redacted exports.
  /// It never exposes notification title, content, merchant, or amount.
  static Future<NotificationCaptureStatus> getCaptureStatus() async {
    try {
      final status = await _captureChannel.invokeMapMethod<String, dynamic>(
        'getCaptureStatus',
      );
      if (status == null) return const NotificationCaptureStatus.unavailable();
      return NotificationCaptureStatus.fromMap(status);
    } on MissingPluginException {
      return const NotificationCaptureStatus.unavailable();
    } catch (error) {
      await _nlog.logError('CAPTURE_STATUS', '$error');
      return const NotificationCaptureStatus.unavailable();
    }
  }

  /// Advances only historical incident cursors. Current permission, listener,
  /// backlog, retry, quarantine, dead-letter and migration state remain visible.
  static Future<NotificationCaptureStatus> acknowledgeCaptureHealth() async {
    final status = await _captureChannel.invokeMapMethod<String, dynamic>(
      'acknowledgeCaptureHealth',
    );
    if (status == null) {
      throw const FormatException('Native capture health snapshot is missing.');
    }
    final parsed = NotificationCaptureStatus.fromMap(status);
    if (!parsed.readSucceeded) {
      throw StateError('Native inbox remained unreadable after acknowledgement.');
    }
    return parsed;
  }

  /// Re-checks system access after returning from Android settings, drains any
  /// durable work that accumulated while the UI was inactive, and asks Android
  /// to rebind a disconnected listener. Failures stay in the native inbox for
  /// the next resume instead of being discarded.
  static Future<void> handleAppResumed() async {
    try {
      if (!await hasNotificationPermission()) {
        _isInitialized = false;
        return;
      }
      await initialize();
      if (!_isInitialized) return;
      await _scheduleInboxDrain();
      if (!await isServiceConnected()) {
        await reconnectService();
      }
    } catch (error) {
      await _nlog.logError('APP_RESUME', '$error');
    }
  }

  static Future<void> initialize({bool forceRequest = false}) {
    if (_isInitialized) return Future<void>.value();
    return _initialization ??= _initialize(forceRequest).whenComplete(() {
      _initialization = null;
    });
  }

  static Future<void> _initialize(bool forceRequest) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();

      var granted = await hasNotificationPermission();
      if (!granted && forceRequest) {
        await requestNotificationPermission();
        granted = await hasNotificationPermission();
      }
      if (!granted) {
        await _nlog.log('INIT', 'Notification access is not granted.');
        return;
      }

      _processor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: await _getDefaultSmsPackage(),
        ),
      );
      _inboxWakeSubscription ??= _captureEvents.receiveBroadcastStream().listen(
        (_) {
          unawaited(_scheduleInboxDrain());
        },
        onError: (_, _) {
          unawaited(_nlog.logError('CAPTURE_WAKE', 'native wake-up failure'));
        },
      );

      // Claiming is acknowledged only after the downstream encrypted database
      // transaction succeeds. A crash or lock failure leaves the row pending.
      await _scheduleInboxDrain();
      if (!await isServiceConnected()) {
        await _nlog.log(
          'INIT',
          'Listener is not connected; requesting rebind.',
        );
        await reconnectService();
      }
      _isInitialized = true;
    } catch (error) {
      await _nlog.logError('INIT', '$error');
      rethrow;
    }
  }

  static Future<String?> _getDefaultSmsPackage() async {
    try {
      return _captureChannel.invokeMethod<String>('getDefaultSmsPackage');
    } on MissingPluginException {
      return null;
    } catch (error) {
      await _nlog.logError('SOURCE_POLICY', '$error');
      return null;
    }
  }

  static Future<String?> _getDefaultSmsPackageStrict() =>
      _captureChannel.invokeMethod<String>('getDefaultSmsPackage');

  /// Serializes claims and ledger writes. A wake-up may arrive while a prior
  /// batch is processing; it will observe the committed state once it runs.
  static Future<void> _scheduleInboxDrain() {
    final completion = Completer<void>();
    _ingestionTail = _ingestionTail.then((_) async {
      try {
        await _drainNativeInbox();
        completion.complete();
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  static Future<void> _drainNativeInbox() async {
    while (true) {
      final captures = await _claimNativeCaptures();
      if (captures.isEmpty) return;

      final outcome = await drainClaimedCaptureBatch<_NativeCapture>(
        captures: captures,
        inboxIdOf: (capture) => capture.inboxId,
        leaseTokenOf: (capture) => capture.leaseToken,
        process: _processCapture,
        acknowledge: _acknowledge,
        release: _release,
        onError: (error, _) => _nlog.logError('CAPTURE_DRAIN', '$error'),
      );
      // Do not spin on a locked/corrupt database. Released rows will be retried
      // after the next wake-up or app initialization.
      if (!outcome.completed) return;
    }
  }

  /// Executes from Android's dedicated background Flutter engine. This path
  /// deliberately does not initialize the EventChannel or any UI stream.
  static Future<void> runHeadlessWorker({
    Duration budget = const Duration(minutes: 7),
    int maxCaptures = 500,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final stopwatch = Stopwatch()..start();

    await runHeadlessWorkerTask(
      drain: () async {
        _processor = NotificationIngestionProcessor(
          sourcePolicy: NotificationSourcePolicy(
            defaultSmsPackage: await _getDefaultSmsPackageStrict(),
          ),
        );
        final result = await drainHeadlessCaptureInbox<_NativeCapture>(
          budget: budget,
          batchLimit: 50,
          maxCaptures: maxCaptures,
          budgetExpired: () => stopwatch.elapsed >= budget,
          claim: (limit) =>
              _claimNativeCaptures(limit: limit, tolerateMissingPlugin: false),
          inboxIdOf: (capture) => capture.inboxId,
          leaseTokenOf: (capture) => capture.leaseToken,
          process: (capture) => _processCapture(capture, emitUiSignals: false),
          acknowledge: _acknowledge,
          release: _release,
          readState: _getHeadlessDrainState,
          onError: (error, _) =>
              _bestEffortLog(() => _nlog.logError('HEADLESS_DRAIN', '$error')),
        );
        try {
          await AppDatabase.instance.prunePrivacyRetention();
        } catch (_) {
          // Maintenance is retried by later workers/startup and never changes
          // native acknowledgement semantics.
        }
        return result;
      },
      complete: (result) =>
          _backgroundControlChannel.invokeMethod<void>('complete', result),
    );
  }

  static Future<List<_NativeCapture>> _claimNativeCaptures({
    int limit = 50,
    bool tolerateMissingPlugin = true,
  }) async {
    try {
      final rows = await _captureChannel.invokeListMethod<dynamic>('claim', {
        'limit': limit,
      });
      if (rows == null) return const [];
      return rows
          .map((row) {
            if (row is! Map<dynamic, dynamic>) {
              throw const FormatException('Malformed native capture row.');
            }
            return _NativeCapture.fromMap(row);
          })
          .toList(growable: false);
    } on MissingPluginException {
      if (!tolerateMissingPlugin) rethrow;
      return const [];
    }
  }

  static Future<int> _acknowledge(String leaseToken, List<String> ids) async {
    final acknowledged = await _captureChannel.invokeMethod<int>(
      'acknowledge',
      {'leaseToken': leaseToken, 'ids': ids},
    );
    if (acknowledged == null) {
      throw const FormatException('Native acknowledgement count is missing.');
    }
    return acknowledged;
  }

  static Future<void> _release(String leaseToken, List<String> ids) async {
    await _captureChannel.invokeMethod<void>('release', {
      'leaseToken': leaseToken,
      'ids': ids,
    });
  }

  static Future<NativeHeadlessDrainState> _getHeadlessDrainState() async {
    final state = await _captureChannel.invokeMapMethod<String, dynamic>(
      'getHeadlessDrainState',
    );
    if (state == null) {
      throw const FormatException('Native headless drain state is missing.');
    }
    final outstanding = (state['outstandingCount'] as num?)?.toInt();
    final nextEligible = (state['nextEligibleAtMillis'] as num?)?.toInt();
    if (outstanding == null || outstanding < 0) {
      throw const FormatException('Invalid native outstanding count.');
    }
    return NativeHeadlessDrainState(
      outstandingCount: outstanding,
      nextEligibleAtMillis: nextEligible,
    );
  }

  static Future<void> _processCapture(
    _NativeCapture capture, {
    bool emitUiSignals = true,
  }) async {
    unawaited(
      _bestEffortLog(
        () => _nlog.logNotificationReceived(
          packageName: capture.packageName,
          hasRemoved: capture.hasRemoved,
          notificationId: capture.notificationId,
          postedAtMillis: capture.postTime,
        ),
      ),
    );
    final result = await _processor.ingest(
      NotificationEnvelope(
        packageName: capture.packageName,
        captureReceiptId: capture.captureReceiptId,
        notificationKey: capture.notificationKey,
        notificationId: capture.notificationId,
        notificationTag: capture.notificationTag,
        title: capture.title,
        content: capture.content,
        hasRemoved: capture.hasRemoved,
        postedAt: capture.postTime > 0
            ? DateTime.fromMillisecondsSinceEpoch(capture.postTime)
            : null,
        ingestedAt: captureIngestedAt(capture.capturedAtMillis, DateTime.now()),
      ),
    );
    unawaited(
      _bestEffortLog(
        () => _nlog.log(
          'INGEST',
          'source=native-inbox disposition=${result.disposition.name} '
              'rawId=${result.rawEventId ?? '-'} '
              'code=${result.diagnosticCode ?? 'none'} '
              'replay=${result.isReceiptReplay}',
        ),
      ),
    );
    if (emitUiSignals) {
      dispatchIngestionResult(
        result: result,
        onTransactionIngested: () => _onTransactionIngested.add(null),
        onReviewInboxChanged: () => _onReviewInboxChanged.add(null),
      );
    }
  }

  static Future<void> _bestEffortLog(Future<void> Function() write) async {
    try {
      await write();
    } catch (_) {
      // Local diagnostics must never prevent native acknowledgement.
    }
  }

  static Future<void> dispose() async {
    await _inboxWakeSubscription?.cancel();
    _inboxWakeSubscription = null;
    _isInitialized = false;
  }
}

class _NativeCapture {
  const _NativeCapture({
    required this.inboxId,
    required this.leaseToken,
    required this.packageName,
    required this.notificationId,
    required this.postTime,
    required this.capturedAtMillis,
    required this.hasRemoved,
    this.captureReceiptId,
    this.notificationKey,
    this.notificationTag,
    this.title,
    this.content,
  });

  final String inboxId;
  final String? captureReceiptId;
  final String leaseToken;
  final String packageName;
  final String? notificationKey;
  final int notificationId;
  final String? notificationTag;
  final String? title;
  final String? content;
  final int postTime;
  final int capturedAtMillis;
  final bool hasRemoved;

  factory _NativeCapture.fromMap(Map<dynamic, dynamic> map) => _NativeCapture(
    inboxId: map['inboxId']! as String,
    captureReceiptId: map['captureReceiptId'] as String?,
    leaseToken: map['leaseToken']! as String,
    packageName: map['packageName']! as String,
    notificationKey: map['notificationKey'] as String?,
    notificationId: map['notificationId']! as int,
    notificationTag: map['notificationTag'] as String?,
    title: map['title'] as String?,
    content: map['content'] as String?,
    postTime: (map['postTime'] as num?)?.toInt() ?? 0,
    capturedAtMillis: (map['capturedAtMillis'] as num?)?.toInt() ?? 0,
    hasRemoved: map['hasRemoved'] as bool? ?? false,
  );
}

class NotificationCaptureStatus {
  const NotificationCaptureStatus({
    required this.isAvailable,
    required this.readSucceeded,
    required this.accessGranted,
    required this.listenerConnected,
    required this.listenerChangedAtMillis,
    required this.lastCapturedAtMillis,
    required this.lastAcknowledgedAtMillis,
    required this.acknowledgedCount,
    required this.legacyCapacityDropsLifetime,
    required this.legacyCapacityEvictionsLifetime,
    required this.storageFailures,
    required this.recoveryFailures,
    required this.storageFailuresBaseline,
    required this.recoveryFailuresBaseline,
    required this.legacyMigrationAttempts,
    required this.legacyMigrationMigrated,
    required this.legacyMigrationFailures,
    required this.legacyMigrationPending,
    required this.legacyMigrationLastAttemptAtMillis,
    required this.pendingCount,
    required this.leasedCount,
    required this.retryingCount,
    required this.quarantinedCount,
    required this.deadLetterCount,
    required this.capacityRejectedCount,
    required this.capacityEvictedCount,
    required this.capacityRejectedBaseline,
    required this.capacityEvictedBaseline,
    required this.healthAcknowledgedAtMillis,
    required this.workerLastSuccessAtMillis,
    required this.workerLastRetryAtMillis,
    required this.workerLastFailureAtMillis,
    required this.workerLastDeferredLockedAtMillis,
    required this.workerRetryCount,
    required this.workerFailureCount,
    required this.workerDeferredLockedCount,
    required this.workerRetryBaseline,
    required this.workerFailureBaseline,
    required this.workerDeferredLockedBaseline,
    this.workerLastIncidentReason,
    this.oldestPendingAtMillis,
    this.oldestLeasedAtMillis,
  });

  const NotificationCaptureStatus.unavailable()
    : isAvailable = false,
      readSucceeded = false,
      accessGranted = false,
      listenerConnected = false,
      listenerChangedAtMillis = 0,
      lastCapturedAtMillis = 0,
      lastAcknowledgedAtMillis = 0,
      acknowledgedCount = 0,
      legacyCapacityDropsLifetime = 0,
      legacyCapacityEvictionsLifetime = 0,
      storageFailures = 0,
      recoveryFailures = 0,
      storageFailuresBaseline = 0,
      recoveryFailuresBaseline = 0,
      legacyMigrationAttempts = 0,
      legacyMigrationMigrated = 0,
      legacyMigrationFailures = 0,
      legacyMigrationPending = 0,
      legacyMigrationLastAttemptAtMillis = 0,
      pendingCount = 0,
      leasedCount = 0,
      retryingCount = 0,
      quarantinedCount = 0,
      deadLetterCount = 0,
      capacityRejectedCount = 0,
      capacityEvictedCount = 0,
      capacityRejectedBaseline = 0,
      capacityEvictedBaseline = 0,
      healthAcknowledgedAtMillis = 0,
      workerLastSuccessAtMillis = 0,
      workerLastRetryAtMillis = 0,
      workerLastFailureAtMillis = 0,
      workerLastDeferredLockedAtMillis = 0,
      workerRetryCount = 0,
      workerFailureCount = 0,
      workerDeferredLockedCount = 0,
      workerRetryBaseline = 0,
      workerFailureBaseline = 0,
      workerDeferredLockedBaseline = 0,
      workerLastIncidentReason = null,
      oldestPendingAtMillis = null,
      oldestLeasedAtMillis = null;

  final bool isAvailable;
  final bool readSucceeded;
  final bool accessGranted;
  final bool listenerConnected;
  final int listenerChangedAtMillis;
  final int lastCapturedAtMillis;
  final int lastAcknowledgedAtMillis;
  final int acknowledgedCount;
  final int legacyCapacityDropsLifetime;
  final int legacyCapacityEvictionsLifetime;
  final int storageFailures;
  final int recoveryFailures;
  final int storageFailuresBaseline;
  final int recoveryFailuresBaseline;
  final int legacyMigrationAttempts;
  final int legacyMigrationMigrated;
  final int legacyMigrationFailures;
  final int legacyMigrationPending;
  final int legacyMigrationLastAttemptAtMillis;
  final int pendingCount;
  final int leasedCount;
  final int retryingCount;
  final int quarantinedCount;
  final int deadLetterCount;
  final int capacityRejectedCount;
  final int capacityEvictedCount;
  final int capacityRejectedBaseline;
  final int capacityEvictedBaseline;
  final int healthAcknowledgedAtMillis;
  final int workerLastSuccessAtMillis;
  final int workerLastRetryAtMillis;
  final int workerLastFailureAtMillis;
  final int workerLastDeferredLockedAtMillis;
  final int workerRetryCount;
  final int workerFailureCount;
  final int workerDeferredLockedCount;
  final int workerRetryBaseline;
  final int workerFailureBaseline;
  final int workerDeferredLockedBaseline;
  final String? workerLastIncidentReason;
  final int? oldestPendingAtMillis;
  final int? oldestLeasedAtMillis;

  static const pendingBacklogThreshold = Duration(minutes: 15);
  static const leasedBacklogThreshold = Duration(minutes: 20);

  int _since(int total, int baseline) =>
      total > baseline ? total - baseline : 0;

  int get capacityRejectedSinceAcknowledgement =>
      _since(capacityRejectedCount, capacityRejectedBaseline);
  int get capacityEvictedSinceAcknowledgement =>
      _since(capacityEvictedCount, capacityEvictedBaseline);
  int get storageFailuresSinceAcknowledgement =>
      _since(storageFailures, storageFailuresBaseline);
  int get recoveryFailuresSinceAcknowledgement =>
      _since(recoveryFailures, recoveryFailuresBaseline);
  int get workerRetriesSinceAcknowledgement =>
      _since(workerRetryCount, workerRetryBaseline);
  int get workerFailuresSinceAcknowledgement =>
      _since(workerFailureCount, workerFailureBaseline);
  int get workerDeferredLockedSinceAcknowledgement =>
      _since(workerDeferredLockedCount, workerDeferredLockedBaseline);

  bool get hasAcknowledgementEligibleIncidents =>
      readSucceeded &&
      (capacityRejectedSinceAcknowledgement > 0 ||
          capacityEvictedSinceAcknowledgement > 0 ||
          storageFailuresSinceAcknowledgement > 0 ||
          recoveryFailuresSinceAcknowledgement > 0 ||
          workerRetriesSinceAcknowledgement > 0 ||
          workerFailuresSinceAcknowledgement > 0 ||
          workerDeferredLockedSinceAcknowledgement > 0);

  bool hasStaleBacklogAt(DateTime now) {
    final nowMillis = now.millisecondsSinceEpoch;
    bool stale(int? oldest, Duration threshold) =>
        oldest != null &&
        oldest > 0 &&
        oldest <= nowMillis - threshold.inMilliseconds;
    return stale(oldestPendingAtMillis, pendingBacklogThreshold) ||
        stale(oldestLeasedAtMillis, leasedBacklogThreshold);
  }

  bool needsAttentionAt(DateTime now) =>
      !isAvailable ||
      !readSucceeded ||
      !accessGranted ||
      !listenerConnected ||
      hasAcknowledgementEligibleIncidents ||
      legacyMigrationPending > 0 ||
      retryingCount > 0 ||
      quarantinedCount > 0 ||
      deadLetterCount > 0 ||
      hasStaleBacklogAt(now);

  bool get needsAttention => needsAttentionAt(DateTime.now());

  factory NotificationCaptureStatus.fromMap(Map<String, dynamic> map) {
    int value(String key) => (map[key] as num?)?.toInt() ?? 0;
    int? nullableValue(String key) => (map[key] as num?)?.toInt();
    return NotificationCaptureStatus(
      isAvailable: true,
      readSucceeded: map['readSucceeded'] as bool? ?? false,
      accessGranted: map['accessGranted'] as bool? ?? false,
      listenerConnected: map['listenerConnected'] as bool? ?? false,
      listenerChangedAtMillis: value('listenerChangedAtMillis'),
      lastCapturedAtMillis: value('lastCapturedAtMillis'),
      lastAcknowledgedAtMillis: value('lastAcknowledgedAtMillis'),
      acknowledgedCount: value('acknowledgedCount'),
      legacyCapacityDropsLifetime: value('legacyCapacityDropsLifetime'),
      legacyCapacityEvictionsLifetime: value(
        'legacyCapacityEvictionsLifetime',
      ),
      storageFailures: value('storageFailures'),
      recoveryFailures: value('recoveryFailures'),
      storageFailuresBaseline: value('storageFailuresBaseline'),
      recoveryFailuresBaseline: value('recoveryFailuresBaseline'),
      legacyMigrationAttempts: value('legacyMigrationAttempts'),
      legacyMigrationMigrated: value('legacyMigrationMigrated'),
      legacyMigrationFailures: value('legacyMigrationFailures'),
      legacyMigrationPending: value('legacyMigrationPending'),
      legacyMigrationLastAttemptAtMillis: value(
        'legacyMigrationLastAttemptAtMillis',
      ),
      pendingCount: value('pendingCount'),
      leasedCount: value('leasedCount'),
      retryingCount: value('retryingCount'),
      quarantinedCount: value('quarantinedCount'),
      deadLetterCount: value('deadLetterCount'),
      capacityRejectedCount: value('capacityRejectedCount'),
      capacityEvictedCount: value('capacityEvictedCount'),
      capacityRejectedBaseline: value('capacityRejectedBaseline'),
      capacityEvictedBaseline: value('capacityEvictedBaseline'),
      healthAcknowledgedAtMillis: value('healthAcknowledgedAtMillis'),
      workerLastSuccessAtMillis: value('workerLastSuccessAtMillis'),
      workerLastRetryAtMillis: value('workerLastRetryAtMillis'),
      workerLastFailureAtMillis: value('workerLastFailureAtMillis'),
      workerLastDeferredLockedAtMillis: value(
        'workerLastDeferredLockedAtMillis',
      ),
      workerRetryCount: value('workerRetryCount'),
      workerFailureCount: value('workerFailureCount'),
      workerDeferredLockedCount: value('workerDeferredLockedCount'),
      workerRetryBaseline: value('workerRetryBaseline'),
      workerFailureBaseline: value('workerFailureBaseline'),
      workerDeferredLockedBaseline: value('workerDeferredLockedBaseline'),
      workerLastIncidentReason: map['workerLastIncidentReason'] as String?,
      oldestPendingAtMillis: nullableValue('oldestPendingAtMillis'),
      oldestLeasedAtMillis: nullableValue('oldestLeasedAtMillis'),
    );
  }

  Map<String, Object?> toExportMap() => {
    'available': isAvailable,
    'readSucceeded': readSucceeded,
    'accessGranted': accessGranted,
    'listenerConnected': listenerConnected,
    'listenerChangedAtMillis': listenerChangedAtMillis,
    'lastCapturedAtMillis': lastCapturedAtMillis,
    'lastAcknowledgedAtMillis': lastAcknowledgedAtMillis,
    'acknowledgedCount': acknowledgedCount,
    'legacyCapacityDropsLifetime': legacyCapacityDropsLifetime,
    'legacyCapacityEvictionsLifetime': legacyCapacityEvictionsLifetime,
    'storageFailures': storageFailures,
    'recoveryFailures': recoveryFailures,
    'storageFailuresBaseline': storageFailuresBaseline,
    'recoveryFailuresBaseline': recoveryFailuresBaseline,
    'legacyMigrationAttempts': legacyMigrationAttempts,
    'legacyMigrationMigrated': legacyMigrationMigrated,
    'legacyMigrationFailures': legacyMigrationFailures,
    'legacyMigrationPending': legacyMigrationPending,
    'legacyMigrationLastAttemptAtMillis': legacyMigrationLastAttemptAtMillis,
    'pendingCount': pendingCount,
    'leasedCount': leasedCount,
    'retryingCount': retryingCount,
    'quarantinedCount': quarantinedCount,
    'deadLetterCount': deadLetterCount,
    'capacityRejectedCount': capacityRejectedCount,
    'capacityEvictedCount': capacityEvictedCount,
    'capacityRejectedBaseline': capacityRejectedBaseline,
    'capacityEvictedBaseline': capacityEvictedBaseline,
    'healthAcknowledgedAtMillis': healthAcknowledgedAtMillis,
    'workerLastSuccessAtMillis': workerLastSuccessAtMillis,
    'workerLastRetryAtMillis': workerLastRetryAtMillis,
    'workerLastFailureAtMillis': workerLastFailureAtMillis,
    'workerLastDeferredLockedAtMillis': workerLastDeferredLockedAtMillis,
    'workerRetryCount': workerRetryCount,
    'workerFailureCount': workerFailureCount,
    'workerDeferredLockedCount': workerDeferredLockedCount,
    'workerRetryBaseline': workerRetryBaseline,
    'workerFailureBaseline': workerFailureBaseline,
    'workerDeferredLockedBaseline': workerDeferredLockedBaseline,
    'workerLastIncidentReason': workerLastIncidentReason,
    'oldestPendingAtMillis': oldestPendingAtMillis,
    'oldestLeasedAtMillis': oldestLeasedAtMillis,
  };
}
