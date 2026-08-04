import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

abstract interface class DeviceTimeZoneProvider {
  Future<String> getIdentifier();
}

final class PlatformDeviceTimeZoneProvider implements DeviceTimeZoneProvider {
  static const _channel = MethodChannel('expense_tracker/device_timezone');

  @override
  Future<String> getIdentifier() async {
    final identifier = await _channel.invokeMethod<String>('getLocalTimeZone');
    if (identifier == null || identifier.isEmpty) {
      throw StateError('The device did not provide a time zone identifier.');
    }
    return identifier;
  }
}

abstract interface class ReminderNotificationGateway {
  Future<void> initialize();

  Future<bool> requestPermission();

  Future<void> scheduleDaily(TimeOfDay time);

  Future<void> cancel();
}

final class PluginReminderNotificationGateway
    implements ReminderNotificationGateway {
  PluginReminderNotificationGateway({
    FlutterLocalNotificationsPlugin? notificationsPlugin,
    DeviceTimeZoneProvider? timeZoneProvider,
  }) : _notificationsPlugin =
           notificationsPlugin ?? FlutterLocalNotificationsPlugin(),
       _timeZoneProvider = timeZoneProvider ?? PlatformDeviceTimeZoneProvider();

  static const reminderId = 888;

  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final DeviceTimeZoneProvider _timeZoneProvider;
  Future<void>? _initialization;

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      tz_data.initializeTimeZones();
      final deviceTimeZone = await _timeZoneProvider.getIdentifier();
      tz.setLocalLocation(tz.getLocation(deviceTimeZone));

      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const initializationSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );

      await _notificationsPlugin.initialize(settings: initializationSettings);
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  @override
  Future<bool> requestPermission() async {
    await initialize();

    if (Platform.isAndroid) {
      return await _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: false, sound: true) ??
          false;
    }
    if (Platform.isMacOS) {
      return await _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, badge: false, sound: true) ??
          false;
    }
    return false;
  }

  @override
  Future<void> scheduleDaily(TimeOfDay time) async {
    await initialize();

    const androidDetails = AndroidNotificationDetails(
      'daily_missed_txns_channel',
      'Daily Reminder',
      channelDescription:
          'Reminds you to manually add any missed transactions of the day',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    final scheduledDate = nextDailyReminderDate(
      time,
      tz.TZDateTime.now(tz.local),
    );
    await _notificationsPlugin.zonedSchedule(
      id: reminderId,
      title: 'Expense Tracker',
      body: 'Add any missed transactions of the day manually',
      scheduledDate: scheduledDate,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  @override
  Future<void> cancel() async {
    await initialize();
    await _notificationsPlugin.cancel(id: reminderId);
  }
}

tz.TZDateTime nextDailyReminderDate(TimeOfDay time, tz.TZDateTime now) {
  var scheduled = tz.TZDateTime(
    now.location,
    now.year,
    now.month,
    now.day,
    time.hour,
    time.minute,
  );
  if (!scheduled.isAfter(now)) {
    scheduled = tz.TZDateTime(
      now.location,
      now.year,
      now.month,
      now.day + 1,
      time.hour,
      time.minute,
    );
  }
  return scheduled;
}
