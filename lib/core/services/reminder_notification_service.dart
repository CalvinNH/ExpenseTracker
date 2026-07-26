import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ReminderNotificationService {
  ReminderNotificationService._();
  static final ReminderNotificationService instance =
      ReminderNotificationService._();

  static const _enabledKey = 'daily_reminder_enabled';
  static const _hourKey = 'daily_reminder_hour';
  static const _minuteKey = 'daily_reminder_minute';

  final _notificationsPlugin = FlutterLocalNotificationsPlugin();
  final _storage = const FlutterSecureStorage();

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    try {
      await _notificationsPlugin.initialize(initSettings);
      _isInitialized = true;

      // Reschedule on startup if enabled
      if (await isReminderEnabled()) {
        final time = await getReminderTime();
        await scheduleDailyReminder(time);
      }
    } catch (_) {}
  }

  Future<bool> isReminderEnabled() async {
    final val = await _storage.read(key: _enabledKey);
    return val == 'true';
  }

  Future<TimeOfDay> getReminderTime() async {
    final hourStr = await _storage.read(key: _hourKey);
    final minuteStr = await _storage.read(key: _minuteKey);

    final hour = int.tryParse(hourStr ?? '21') ?? 21; // Default 9:00 PM
    final minute = int.tryParse(minuteStr ?? '0') ?? 0;

    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<void> setReminderEnabled(bool enabled) async {
    await _storage.write(key: _enabledKey, value: enabled ? 'true' : 'false');
    if (enabled) {
      final time = await getReminderTime();
      await scheduleDailyReminder(time);
    } else {
      await cancelReminder();
    }
  }

  Future<void> setReminderTime(TimeOfDay time) async {
    await _storage.write(key: _hourKey, value: time.hour.toString());
    await _storage.write(key: _minuteKey, value: time.minute.toString());
    if (await isReminderEnabled()) {
      await scheduleDailyReminder(time);
    }
  }

  Future<void> scheduleDailyReminder(TimeOfDay time) async {
    await cancelReminder();

    const androidDetails = AndroidNotificationDetails(
      'daily_missed_txns_channel',
      'Daily Reminder',
      channelDescription:
          'Reminds you to manually add any missed transactions of the day',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const details = NotificationDetails(android: androidDetails);

    try {
      await _notificationsPlugin.periodicallyShow(
        888,
        'Expense Tracker',
        'Add any missed transactions of the day manually',
        RepeatInterval.daily,
        details,
        androidScheduleMode: AndroidScheduleMode.inexact,
      );
    } catch (_) {}
  }

  Future<void> cancelReminder() async {
    try {
      await _notificationsPlugin.cancel(888);
    } catch (_) {}
  }
}
