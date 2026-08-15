import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const captureChannel = MethodChannel('expense_tracker/notification_capture');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, null);
  });

  test('maps the redacted native capture health snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, (method) async {
          expect(method.method, 'getCaptureStatus');
          return <String, dynamic>{
            'readSucceeded': true,
            'accessGranted': true,
            'listenerConnected': true,
            'listenerChangedAtMillis': 101,
            'lastCapturedAtMillis': 102,
            'lastAcknowledgedAtMillis': 103,
            'acknowledgedCount': 4,
            'legacyCapacityDropsLifetime': 0,
            'legacyCapacityEvictionsLifetime': 2,
            'storageFailures': 0,
            'recoveryFailures': 0,
            'legacyMigrationAttempts': 1,
            'legacyMigrationMigrated': 3,
            'legacyMigrationFailures': 0,
            'legacyMigrationPending': 0,
            'legacyMigrationLastAttemptAtMillis': 100,
            'pendingCount': 1,
            'leasedCount': 0,
            'retryingCount': 0,
            'quarantinedCount': 0,
            'deadLetterCount': 0,
            'capacityRejectedCount': 0,
            'capacityEvictedCount': 2,
            'capacityEvictedBaseline': 0,
            'oldestPendingAtMillis': 99,
            'oldestLeasedAtMillis': null,
          };
        });

    final status = await NotificationService.getCaptureStatus();

    expect(status.isAvailable, isTrue);
    expect(status.needsAttention, isTrue);
    expect(status.pendingCount, 1);
    expect(status.legacyMigrationMigrated, 3);
    expect(status.legacyCapacityEvictionsLifetime, 2);
    expect(status.capacityEvictedCount, 2);
    expect(status.toExportMap(), isNot(contains('content')));
    expect(status.toExportMap(), isNot(contains('title')));
  });

  test('marks listener or storage failures as actionable', () {
    final status = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'accessGranted': true,
      'listenerConnected': false,
      'readSucceeded': true,
      'storageFailures': 1,
    });

    expect(status.needsAttention, isTrue);
  });

  test('marks unresolved legacy migration rows as actionable', () {
    final status = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'accessGranted': true,
      'listenerConnected': true,
      'readSucceeded': true,
      'legacyMigrationFailures': 2,
      'legacyMigrationPending': 1,
    });

    expect(status.needsAttention, isTrue);
    expect(status.legacyMigrationFailures, 2);
    expect(status.legacyMigrationPending, 1);
  });

  test('exposes inbox v2 failure states and marks dead letters actionable', () {
    final status = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'accessGranted': true,
      'listenerConnected': true,
      'readSucceeded': true,
      'quarantinedCount': 2,
      'deadLetterCount': 1,
      'capacityRejectedCount': 3,
      'capacityEvictedCount': 4,
    });

    expect(status.quarantinedCount, 2);
    expect(status.deadLetterCount, 1);
    expect(status.capacityRejectedCount, 3);
    expect(status.capacityEvictedCount, 4);
    expect(status.needsAttention, isTrue);
    expect(status.toExportMap(), containsPair('deadLetterCount', 1));
  });

  test('every persisted loss or retry counter is actionable', () {
    for (final field in <String>[
      'capacityRejectedCount',
      'capacityEvictedCount',
      'recoveryFailures',
      'workerRetryCount',
      'workerFailureCount',
      'workerDeferredLockedCount',
      'quarantinedCount',
      'deadLetterCount',
    ]) {
      final status = NotificationCaptureStatus.fromMap(<String, dynamic>{
        'accessGranted': true,
        'listenerConnected': true,
        'readSucceeded': true,
        field: 1,
      });

      expect(status.needsAttention, isTrue, reason: field);
    }
  });

  test('acknowledged historical incidents do not mask current failures', () {
    final reviewed = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'readSucceeded': true,
      'accessGranted': true,
      'listenerConnected': true,
      'legacyCapacityDropsLifetime': 50,
      'legacyCapacityEvictionsLifetime': 60,
      'capacityRejectedCount': 4,
      'capacityRejectedBaseline': 4,
      'storageFailures': 3,
      'storageFailuresBaseline': 3,
      'workerRetryCount': 2,
      'workerRetryBaseline': 2,
    });

    expect(reviewed.hasAcknowledgementEligibleIncidents, isFalse);
    expect(reviewed.needsAttention, isFalse);

    final currentBacklog = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'readSucceeded': true,
      'accessGranted': true,
      'listenerConnected': true,
      'capacityRejectedCount': 4,
      'capacityRejectedBaseline': 4,
      'retryingCount': 1,
    });
    expect(currentBacklog.needsAttention, isTrue);
  });

  test('native read failure is never a false healthy zero', () {
    final status = NotificationCaptureStatus.fromMap(<String, dynamic>{
      'readSucceeded': false,
      'accessGranted': true,
      'listenerConnected': true,
    });

    expect(status.needsAttention, isTrue);
    expect(status.hasAcknowledgementEligibleIncidents, isFalse);
  });

  test('only aged ordinary backlog is actionable', () {
    final now = DateTime.fromMillisecondsSinceEpoch(2_000_000);
    NotificationCaptureStatus statusWithOldest(int oldest) =>
        NotificationCaptureStatus.fromMap(<String, dynamic>{
          'readSucceeded': true,
          'accessGranted': true,
          'listenerConnected': true,
          'pendingCount': 1,
          'oldestPendingAtMillis': oldest,
        });

    expect(statusWithOldest(1_900_000).needsAttentionAt(now), isFalse);
    expect(statusWithOldest(1_000_000).needsAttentionAt(now), isTrue);
  });

  test('health acknowledgement uses the reusable capture channel', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, (method) async {
          expect(method.method, 'acknowledgeCaptureHealth');
          return <String, dynamic>{
            'readSucceeded': true,
            'accessGranted': true,
            'listenerConnected': true,
            'capacityRejectedCount': 3,
            'capacityRejectedBaseline': 3,
          };
        });

    final status = await NotificationService.acknowledgeCaptureHealth();
    expect(status.capacityRejectedSinceAcknowledgement, 0);
    expect(status.needsAttention, isFalse);
  });

  test('health acknowledgement rejects an unreadable returned snapshot', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, (_) async {
          return <String, dynamic>{
            'readSucceeded': false,
            'accessGranted': true,
            'listenerConnected': true,
          };
        });

    await expectLater(
      NotificationService.acknowledgeCaptureHealth(),
      throwsStateError,
    );
  });
}
