import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps the previously granted notification listener component', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final compatibilityService = File(
      'android/app/src/main/kotlin/notification/listener/service/'
      'NotificationListener.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();
    final listener = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'TransactionNotificationListener.kt',
    ).readAsStringSync();

    const legacyClass = 'notification.listener.service.NotificationListener';
    expect(manifest, contains('android:name="$legacyClass"'));
    expect(
      manifest,
      isNot(contains('android:name=".TransactionNotificationListener"')),
    );
    expect(
      compatibilityService,
      contains('package notification.listener.service'),
    );
    expect(
      compatibilityService,
      contains(
        'class NotificationListener : TransactionNotificationListener()',
      ),
    );
    expect(
      bridge,
      contains('TransactionNotificationListener.LISTENER_COMPONENT_CLASS'),
    );
    expect(
      listener,
      contains('const val LISTENER_COMPONENT_CLASS'),
      reason: 'The listener ComponentName must be centralized',
    );
  });

  test('legacy queue migration clears only durably represented rows', () {
    final migration = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'LegacyNotificationQueueMigration.kt',
    ).readAsStringSync();

    expect(migration, contains('"notification_ingestion_queue"'));
    expect(migration, contains('"pending_notifications"'));
    expect(migration, contains('NativeNotificationInbox.enqueue'));
    expect(migration, contains('outcome.isDurablyRepresented()'));
    expect(
      migration,
      contains('NativeNotificationInbox.EnqueueOutcome.stored ||'),
    );
    expect(
      migration,
      contains('NativeNotificationInbox.EnqueueOutcome.storedAfterEviction ||'),
    );
    expect(
      migration,
      contains('NativeNotificationInbox.EnqueueOutcome.duplicate'),
    );
    expect(migration, contains('remaining.put(item)'));
    expect(migration, contains('hasRemoved = optBoolean("hasRemoved", false)'));
    expect(
      migration,
      contains('.putString(QUEUE_KEY, remaining.toString()).commit()'),
    );
    expect(migration, contains('recordLegacyMigration'));
  });

  test('native capture preserves removal state through the Dart envelope', () {
    final inbox = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NativeNotificationInbox.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();
    final service = File(
      'lib/features/ingestion/notification_service.dart',
    ).readAsStringSync();

    expect(inbox, contains('put("hasRemoved", capture.hasRemoved)'));
    expect(
      inbox,
      contains('hasRemoved = json.optBoolean("hasRemoved", false)'),
    );
    expect(bridge, contains('"hasRemoved" to item.capture.hasRemoved'));
    expect(
      bridge,
      contains('"capturedAtMillis" to item.capture.capturedAtMillis'),
    );
    expect(
      service,
      contains("hasRemoved: map['hasRemoved'] as bool? ?? false"),
    );
    expect(service, contains('hasRemoved: capture.hasRemoved'));
    expect(service, contains('ingestedAt: captureIngestedAt('));
  });

  test('native inbox identity reaches the durable raw event receipt', () {
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();
    final service = File(
      'lib/features/ingestion/notification_service.dart',
    ).readAsStringSync();
    final processor = File(
      'lib/features/ingestion/notification_ingestion_processor.dart',
    ).readAsStringSync();
    final rawEvent = File(
      'lib/core/models/raw_notification_event.dart',
    ).readAsStringSync();
    final database = File(
      'lib/core/database/app_database.dart',
    ).readAsStringSync();

    expect(bridge, contains('"inboxId" to item.id'));
    expect(bridge, contains('"captureReceiptId" to item.eventHmac'));
    expect(
      service,
      contains("captureReceiptId: map['captureReceiptId'] as String?"),
    );
    expect(service, contains('captureReceiptId: capture.captureReceiptId'));
    expect(
      processor,
      contains('normalizedCaptureReceiptId ?? envelope.captureReceiptId'),
    );
    expect(rawEvent, contains("'capture_receipt_id': captureReceiptId"));
    expect(database, contains('static const databaseVersion = 12'));
    expect(database, contains('idx_raw_capture_receipt_id'));
  });

  test('native inbox v1 upgrades in place to the retry-aware v2 schema', () {
    final inbox = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NativeNotificationInbox.kt',
    ).readAsStringSync();

    expect(inbox, contains('private const val DATABASE_VERSION = 2'));
    expect(inbox, contains('if (oldVersion < 2)'));
    for (final column in <String>[
      'decode_failures',
      'next_attempt_at',
      'last_failure_code',
      'last_failure_at',
    ]) {
      expect(inbox, contains('ADD COLUMN $column'));
    }
    expect(inbox, contains('createV2Objects(database)'));
    expect(inbox, contains('CREATE TABLE IF NOT EXISTS capture_incidents'));
  });

  test('headless worker is offline, bounded, unlock-aware, and durable', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final scheduler = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationDrainScheduler.kt',
    ).readAsStringSync();
    final worker = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationDrainWorker.kt',
    ).readAsStringSync();

    expect(gradle, contains('androidx.work:work-runtime-ktx:2.9.0'));
    expect(scheduler, contains('ExistingWorkPolicy.APPEND_OR_REPLACE'));
    expect(scheduler, contains('NetworkType.NOT_REQUIRED'));
    expect(scheduler, contains('BackoffPolicy.EXPONENTIAL'));
    expect(worker, contains('isUserUnlocked'));
    expect(worker, contains('withTimeout(WORKER_TIMEOUT_MILLIS)'));
    expect(worker, contains('notificationWorkerEntrypoint'));
    expect(worker, contains('expense_tracker/notification_background_control'));
    expect(worker, contains('NativeNotificationInbox.strictDrainState'));
    expect(
      worker.indexOf('close(releaseOutstanding = true)'),
      lessThan(worker.indexOf('?.destroy()')),
    );
    expect(manifest, contains('.NotificationDrainRescheduleReceiver'));
    expect(manifest, contains('android.intent.action.BOOT_COMPLETED'));
    expect(manifest, contains('android.intent.action.USER_UNLOCKED'));
    expect(manifest, contains('android.intent.action.MY_PACKAGE_REPLACED'));
  });

  test('capture acknowledgement and scheduling preserve committed work', () {
    final inbox = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NativeNotificationInbox.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationCaptureChannelBridge.kt',
    ).readAsStringSync();
    final listener = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'TransactionNotificationListener.kt',
    ).readAsStringSync();

    expect(inbox, contains('fun acknowledgeStrict'));
    expect(inbox, contains('check(acknowledged == expected)'));
    expect(inbox, contains('fun strictDrainState'));
    expect(bridge, contains('result.success(acknowledged)'));
    expect(bridge, contains('"getHeadlessDrainState"'));
    expect(listener, contains('NotificationDrainScheduler.scheduleOutstanding(this)'));
    expect(
      inbox.indexOf('NotificationDrainScheduler.schedule(context)'),
      greaterThan(inbox.indexOf('if (outcome != EnqueueOutcome.storageError)')),
      reason: 'WorkManager scheduling must happen after durability is classified',
    );
    expect(inbox, contains('Unable to schedule notification inbox drain'));
  });
}
