import 'package:expense_tracker/core/services/reminder_notification_gateway.dart';
import 'package:expense_tracker/core/services/reminder_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  test(
    'enabling requests permission and schedules the stored local time',
    () async {
      final gateway = _FakeReminderGateway();
      final store = _MemoryReminderStore({
        ReminderNotificationService.hourKey: '7',
        ReminderNotificationService.minuteKey: '30',
      });
      final service = ReminderNotificationService(
        notifications: gateway,
        storage: store,
      );

      final result = await service.setReminderEnabled(true);

      expect(result, ReminderUpdateResult.enabled);
      expect(gateway.initializeCalls, 1);
      expect(gateway.permissionCalls, 1);
      expect(gateway.scheduledTimes, [const TimeOfDay(hour: 7, minute: 30)]);
      expect(store.values[ReminderNotificationService.enabledKey], 'true');
    },
  );

  test('permission denial leaves reminders disabled and unscheduled', () async {
    final gateway = _FakeReminderGateway(permissionGranted: false);
    final store = _MemoryReminderStore();
    final service = ReminderNotificationService(
      notifications: gateway,
      storage: store,
    );

    final result = await service.setReminderEnabled(true);

    expect(result, ReminderUpdateResult.permissionDenied);
    expect(gateway.scheduledTimes, isEmpty);
    expect(gateway.cancelCalls, 1);
    expect(store.values[ReminderNotificationService.enabledKey], 'false');
  });

  test('disabling cancels the pending reminder before persisting', () async {
    final gateway = _FakeReminderGateway();
    final store = _MemoryReminderStore({
      ReminderNotificationService.enabledKey: 'true',
    });
    final service = ReminderNotificationService(
      notifications: gateway,
      storage: store,
    );

    final result = await service.setReminderEnabled(false);

    expect(result, ReminderUpdateResult.disabled);
    expect(gateway.cancelCalls, 1);
    expect(store.values[ReminderNotificationService.enabledKey], 'false');
  });

  test(
    'changing an enabled reminder reschedules before saving its time',
    () async {
      final gateway = _FakeReminderGateway();
      final store = _MemoryReminderStore({
        ReminderNotificationService.enabledKey: 'true',
        ReminderNotificationService.hourKey: '21',
        ReminderNotificationService.minuteKey: '0',
      });
      final service = ReminderNotificationService(
        notifications: gateway,
        storage: store,
      );

      final updated = await service.setReminderTime(
        const TimeOfDay(hour: 8, minute: 45),
      );

      expect(updated, isTrue);
      expect(gateway.scheduledTimes, [const TimeOfDay(hour: 8, minute: 45)]);
      expect(store.values[ReminderNotificationService.hourKey], '8');
      expect(store.values[ReminderNotificationService.minuteKey], '45');
    },
  );

  test(
    'a scheduling failure does not save a time that is not active',
    () async {
      final gateway = _FakeReminderGateway(throwWhenScheduling: true);
      final store = _MemoryReminderStore({
        ReminderNotificationService.enabledKey: 'true',
        ReminderNotificationService.hourKey: '21',
        ReminderNotificationService.minuteKey: '0',
      });
      final service = ReminderNotificationService(
        notifications: gateway,
        storage: store,
      );

      final updated = await service.setReminderTime(
        const TimeOfDay(hour: 8, minute: 45),
      );

      expect(updated, isFalse);
      expect(store.values[ReminderNotificationService.hourKey], '21');
      expect(store.values[ReminderNotificationService.minuteKey], '0');
    },
  );

  test(
    'startup restores an enabled reminder without prompting again',
    () async {
      final gateway = _FakeReminderGateway();
      final store = _MemoryReminderStore({
        ReminderNotificationService.enabledKey: 'true',
        ReminderNotificationService.hourKey: '18',
        ReminderNotificationService.minuteKey: '5',
      });
      final service = ReminderNotificationService(
        notifications: gateway,
        storage: store,
      );

      await service.initialize();

      expect(gateway.permissionCalls, 0);
      expect(gateway.scheduledTimes, [const TimeOfDay(hour: 18, minute: 5)]);
    },
  );

  test('invalid stored reminder values fall back to 9 PM', () async {
    final service = ReminderNotificationService(
      notifications: _FakeReminderGateway(),
      storage: _MemoryReminderStore({
        ReminderNotificationService.hourKey: '99',
        ReminderNotificationService.minuteKey: '-4',
      }),
    );

    expect(
      await service.getReminderTime(),
      const TimeOfDay(hour: 21, minute: 0),
    );
  });

  test('next daily occurrence uses today when the selected time is ahead', () {
    final now = tz.TZDateTime(tz.UTC, 2026, 7, 31, 20);

    final scheduled = nextDailyReminderDate(
      const TimeOfDay(hour: 21, minute: 15),
      now,
    );

    expect(scheduled, tz.TZDateTime(tz.UTC, 2026, 7, 31, 21, 15));
  });

  test('next daily occurrence advances a day when the time has passed', () {
    final now = tz.TZDateTime(tz.UTC, 2026, 7, 31, 22);

    final scheduled = nextDailyReminderDate(
      const TimeOfDay(hour: 21, minute: 15),
      now,
    );

    expect(scheduled, tz.TZDateTime(tz.UTC, 2026, 8, 1, 21, 15));
  });

  test('timezone data supports legacy identifiers returned by Android', () {
    expect(tz.getLocation('Asia/Calcutta').name, 'Asia/Calcutta');
  });
}

final class _MemoryReminderStore implements ReminderSettingsStore {
  _MemoryReminderStore([Map<String, String>? initialValues])
    : values = {...?initialValues};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _FakeReminderGateway implements ReminderNotificationGateway {
  _FakeReminderGateway({
    this.permissionGranted = true,
    this.throwWhenScheduling = false,
  });

  final bool permissionGranted;
  final bool throwWhenScheduling;
  int initializeCalls = 0;
  int permissionCalls = 0;
  int cancelCalls = 0;
  final List<TimeOfDay> scheduledTimes = [];

  @override
  Future<void> initialize() async {
    initializeCalls += 1;
  }

  @override
  Future<bool> requestPermission() async {
    permissionCalls += 1;
    return permissionGranted;
  }

  @override
  Future<void> scheduleDaily(TimeOfDay time) async {
    if (throwWhenScheduling) throw Exception('scheduling failed');
    scheduledTimes.add(time);
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }
}
