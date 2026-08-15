import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native health cannot report a failed inbox read as healthy zero', () {
    final inbox = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NativeNotificationInbox.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();

    expect(inbox, contains('val readSucceeded: Boolean'));
    expect(inbox, contains('Status(false, 0, 0, 0, 0, 0, 0, 0'));
    expect(bridge, contains('"readSucceeded" to inbox.readSucceeded'));
  });

  test('capacity health uses canonical inbox incidents and explicit history', () {
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();

    expect(
      bridge,
      contains('"capacityRejectedCount" to inbox.capacityRejectedCount'),
    );
    expect(
      bridge,
      contains('"capacityEvictedCount" to inbox.capacityEvictedCount'),
    );
    expect(
      bridge,
      contains('"legacyCapacityDropsLifetime" to health.capacityDrops'),
    );
    expect(bridge, isNot(contains('"capacityDrops" to health.capacityDrops')));
  });

  test('new capacity incidents are written only to canonical SQLite', () {
    final listener = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'TransactionNotificationListener.kt',
    ).readAsStringSync();
    final migration = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'LegacyNotificationQueueMigration.kt',
    ).readAsStringSync();
    final inbox = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NativeNotificationInbox.kt',
    ).readAsStringSync();

    expect(listener, isNot(contains('recordCapacityDrop')));
    expect(listener, isNot(contains('recordCapacityEviction')));
    expect(migration, isNot(contains('recordCapacityDrop')));
    expect(migration, isNot(contains('recordCapacityEviction')));
    expect(inbox, contains('recordIncident(database, "capacity_rejected"'));
    expect(inbox, contains('recordIncident(database, "capacity_evicted"'));
  });

  test('incident baselines and worker telemetry are device protected', () {
    final baselines = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureIncidentBaselines.kt',
    ).readAsStringSync();
    final workerHealth = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationDrainWorkerHealth.kt',
    ).readAsStringSync();
    final worker = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationDrainWorker.kt',
    ).readAsStringSync();

    expect(baselines, contains('createDeviceProtectedStorageContext'));
    expect(baselines, contains('check(inbox.readSucceeded)'));
    expect(baselines, contains('check(committed)'));
    expect(workerHealth, contains('createDeviceProtectedStorageContext'));
    expect(workerHealth, contains('enum class Reason'));
    expect(workerHealth, contains('synchronized(lock)'));
    expect(workerHealth, contains('if (value == Long.MAX_VALUE)'));
    expect(worker, contains('recordDeferredLocked'));
    expect(worker, contains('recordSuccess'));
    expect(worker, contains('recordRetry'));
    expect(worker, contains('recordFailure'));
  });

  test('one reusable channel exposes review acknowledgement', () {
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();
    expect(bridge, contains('"acknowledgeCaptureHealth"'));
    expect(bridge, contains('NotificationCaptureIncidentBaselines.acknowledge'));
  });
}
