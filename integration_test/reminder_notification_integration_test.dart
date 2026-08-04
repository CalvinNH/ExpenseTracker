import 'package:expense_tracker/core/services/reminder_notification_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('daily reminder registers and cancels a native pending alarm', (
    tester,
  ) async {
    final gateway = PluginReminderNotificationGateway();
    addTearDown(gateway.cancel);

    await gateway.initialize();
    await gateway.scheduleDaily(const TimeOfDay(hour: 21, minute: 0));

    final pending = await FlutterLocalNotificationsPlugin()
        .pendingNotificationRequests();
    expect(
      pending.any(
        (notification) =>
            notification.id == PluginReminderNotificationGateway.reminderId,
      ),
      isTrue,
    );

    await gateway.cancel();
    final remaining = await FlutterLocalNotificationsPlugin()
        .pendingNotificationRequests();
    expect(
      remaining.any(
        (notification) =>
            notification.id == PluginReminderNotificationGateway.reminderId,
      ),
      isFalse,
    );
  });
}
