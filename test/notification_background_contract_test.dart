import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'durable worker is uniquely scheduled without a network requirement',
    () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      final scheduler = File(
        'android/app/src/main/kotlin/com/calvin/expense_tracker/'
        'NotificationDrainScheduler.kt',
      ).readAsStringSync();

      expect(gradle, contains('androidx.work:work-runtime-ktx:2.9.0'));
      expect(scheduler, contains('enqueueUniqueWork('));
      expect(scheduler, contains('ExistingWorkPolicy.APPEND_OR_REPLACE'));
      expect(scheduler, contains('ExistingWorkPolicy.KEEP'));
      expect(scheduler, contains('ExistingWorkPolicy.REPLACE'));
      expect(scheduler, contains('NetworkType.NOT_REQUIRED'));
      expect(scheduler, contains('BackoffPolicy.EXPONENTIAL'));
      expect(scheduler, contains('scheduleOutstanding'));
      expect(scheduler, contains('workerStarted'));
      expect(scheduler, contains('workerFinished'));
      expect(scheduler, contains('currentGeneration != startedGeneration'));
    },
  );

  test('boot unlock and package replacement receiver matches its class', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final receiver = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationDrainRescheduleReceiver.kt',
    ).readAsStringSync();

    expect(receiver, contains('class NotificationDrainRescheduleReceiver'));
    expect(
      manifest,
      contains('android:name=".NotificationDrainRescheduleReceiver"'),
    );
    expect(manifest, contains('android:exported="false"'));
    expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
    expect(manifest, contains('android.intent.action.USER_UNLOCKED'));
    expect(manifest, contains('android.intent.action.MY_PACKAGE_REPLACED'));
    expect(
      receiver,
      contains('NotificationDrainScheduler.scheduleOutstanding'),
    );
  });

  test(
    'worker defers locked storage and always destroys its headless engine',
    () {
      final worker = File(
        'android/app/src/main/kotlin/com/calvin/expense_tracker/'
        'NotificationDrainWorker.kt',
      ).readAsStringSync();

      expect(worker, contains('isUserUnlocked'));
      expect(worker, contains('return Result.retry()'));
      expect(worker, contains('withTimeout(WORKER_TIMEOUT_MILLIS)'));
      expect(worker, contains('notificationWorkerEntrypoint'));
      expect(worker, isNot(contains('startActivity(')));

      final bridgeClose = worker.indexOf(
        'captureBridge.getAndSet(null)?.close',
      );
      final engineDestroy = worker.indexOf('engine.getAndSet(null)?.destroy()');
      expect(bridgeClose, greaterThanOrEqualTo(0));
      expect(engineDestroy, greaterThan(bridgeClose));
    },
  );

  test(
    'capture acknowledgement is counted and headless UI calls are rejected',
    () {
      final bridge = File(
        'android/app/src/main/kotlin/com/calvin/expense_tracker/'
        'NotificationCaptureChannelBridge.kt',
      ).readAsStringSync();
      final activity = File(
        'android/app/src/main/kotlin/com/calvin/expense_tracker/MainActivity.kt',
      ).readAsStringSync();

      expect(bridge, contains('headless_ui_forbidden'));
      expect(bridge, contains('val acknowledged ='));
      expect(bridge, contains('result.success(acknowledged)'));
      expect(activity, contains('NotificationCaptureChannelBridge('));
      expect(
        activity,
        isNot(contains('"expense_tracker/notification_capture"')),
      );
    },
  );

  test(
    'scheduling cannot change an already decided durable enqueue outcome',
    () {
      final inbox = File(
        'android/app/src/main/kotlin/com/calvin/expense_tracker/'
        'NativeNotificationInbox.kt',
      ).readAsStringSync();
      final start = inbox.indexOf('fun enqueue(');
      final end = inbox.indexOf('fun claim(', start);
      final enqueue = inbox.substring(start, end);

      expect(enqueue, contains('val outcome = synchronized(lock)'));
      final durableDecision = enqueue.indexOf(
        'if (outcome != EnqueueOutcome.storageError)',
      );
      final schedule = enqueue.indexOf('NotificationDrainScheduler.schedule');
      expect(durableDecision, greaterThan(0));
      expect(schedule, greaterThan(durableDecision));
      expect(
        RegExp(r'NotificationDrainScheduler\.schedule').allMatches(enqueue),
        hasLength(1),
      );
      expect(enqueue, contains('return outcome'));
    },
  );

  test('release artifact keeps the no-network guarantee', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    expect(manifest, isNot(contains('android.permission.INTERNET')));
    expect(gradle, contains('verifyReleaseOffline'));
    expect(gradle, contains('android.permission.INTERNET'));
  });
}
