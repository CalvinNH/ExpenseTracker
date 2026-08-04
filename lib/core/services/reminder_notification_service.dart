import 'package:expense_tracker/core/services/reminder_notification_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ReminderUpdateResult { enabled, disabled, permissionDenied, failed }

abstract interface class ReminderSettingsStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

final class SecureReminderSettingsStore implements ReminderSettingsStore {
  const SecureReminderSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class ReminderNotificationService {
  ReminderNotificationService({
    ReminderNotificationGateway? notifications,
    ReminderSettingsStore? storage,
  }) : _notifications = notifications ?? PluginReminderNotificationGateway(),
       _storage = storage ?? const SecureReminderSettingsStore();

  static final ReminderNotificationService instance =
      ReminderNotificationService();

  static const enabledKey = 'daily_reminder_enabled';
  static const hourKey = 'daily_reminder_hour';
  static const minuteKey = 'daily_reminder_minute';

  final ReminderNotificationGateway _notifications;
  final ReminderSettingsStore _storage;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      await _notifications.initialize();
      if (await isReminderEnabled()) {
        await _notifications.scheduleDaily(await getReminderTime());
      }
    } catch (_) {
      _initialization = null;
    }
  }

  Future<bool> isReminderEnabled() async {
    final value = await _storage.read(enabledKey);
    return value == 'true';
  }

  Future<TimeOfDay> getReminderTime() async {
    final storedHour = int.tryParse(await _storage.read(hourKey) ?? '');
    final storedMinute = int.tryParse(await _storage.read(minuteKey) ?? '');
    final hour = storedHour != null && storedHour >= 0 && storedHour <= 23
        ? storedHour
        : 21;
    final minute =
        storedMinute != null && storedMinute >= 0 && storedMinute <= 59
        ? storedMinute
        : 0;
    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<ReminderUpdateResult> setReminderEnabled(bool enabled) async {
    if (!enabled) {
      try {
        await _notifications.cancel();
        await _storage.write(enabledKey, 'false');
        return ReminderUpdateResult.disabled;
      } catch (_) {
        return ReminderUpdateResult.failed;
      }
    }

    try {
      await _notifications.initialize();
      if (!await _notifications.requestPermission()) {
        await _notifications.cancel();
        await _storage.write(enabledKey, 'false');
        return ReminderUpdateResult.permissionDenied;
      }

      await _notifications.scheduleDaily(await getReminderTime());
      await _storage.write(enabledKey, 'true');
      return ReminderUpdateResult.enabled;
    } catch (_) {
      try {
        await _notifications.cancel();
        await _storage.write(enabledKey, 'false');
      } catch (_) {}
      return ReminderUpdateResult.failed;
    }
  }

  Future<bool> setReminderTime(TimeOfDay time) async {
    try {
      if (await isReminderEnabled()) {
        await _notifications.scheduleDaily(time);
      }
      await _storage.write(hourKey, time.hour.toString());
      await _storage.write(minuteKey, time.minute.toString());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> scheduleDailyReminder(TimeOfDay time) async {
    try {
      await _notifications.scheduleDaily(time);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> cancelReminder() async {
    try {
      await _notifications.cancel();
      return true;
    } catch (_) {
      return false;
    }
  }
}
