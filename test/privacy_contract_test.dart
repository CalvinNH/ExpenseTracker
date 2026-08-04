import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release Android manifest has no network or backup access', () async {
    final manifest = await File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsString();

    expect(manifest, isNot(contains('android.permission.INTERNET')));
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:usesCleartextTraffic="false"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test(
    'backup and device-transfer rules exclude every app data domain',
    () async {
      final legacyRules = await File(
        'android/app/src/main/res/xml/backup_rules.xml',
      ).readAsString();
      final extractionRules = await File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsString();

      for (final domain in [
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
      ]) {
        expect(legacyRules, contains('domain="$domain" path="."'));
        expect(
          RegExp(
            'domain="$domain" path="\\."',
            multiLine: true,
          ).allMatches(extractionRules),
          hasLength(2),
        );
      }
    },
  );

  test('only CSV export remains user-shareable', () async {
    final settings = await File(
      'lib/features/settings/presentation/settings_screen.dart',
    ).readAsString();
    final notificationLogger = await File(
      'lib/core/services/notification_log_service.dart',
    ).readAsString();

    expect(settings, contains('SharePlus.instance.share'));
    expect(settings, contains('ShareParams('));
    expect(settings, isNot(contains('Share.shareXFiles')));
    expect(settings, contains('Export to CSV'));
    expect(settings, isNot(contains('Export Notification Logs')));
    expect(settings, isNot(contains('notification_templates')));
    expect(settings, isNot(contains('NotificationTemplate')));
    expect(notificationLogger, isNot(contains('Share.share')));
    expect(notificationLogger, contains('if (kReleaseMode) return;'));
  });

  test('CSV sharing uses the built-in-Kotlin-compatible plugin release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('share_plus: ^13.3.0'));
  });

  test('typography is bundled and runtime font fetching is disabled', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final theme = File('lib/core/theme/app_theme.dart').readAsStringSync();

    expect(pubspec, isNot(contains('google_fonts:')));
    expect(pubspec, contains('family: Inter'));
    expect(theme, isNot(contains('GoogleFonts')));
    expect(File('assets/fonts/inter/Inter-Regular.ttf').lengthSync(), 324796);
    expect(File('assets/fonts/inter/Inter-SemiBold.ttf').lengthSync(), 326024);
    expect(File('assets/fonts/inter/Inter-Bold.ttf').lengthSync(), 326444);
    expect(File('assets/fonts/inter/OFL.txt').existsSync(), isTrue);
  });

  test('device authentication has its required platform configuration', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/MainActivity.kt',
    ).readAsStringSync();
    final lightStyles = File(
      'android/app/src/main/res/values/styles.xml',
    ).readAsStringSync();
    final darkStyles = File(
      'android/app/src/main/res/values-night/styles.xml',
    ).readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final authenticator = File(
      'lib/core/security/device_authenticator.dart',
    ).readAsStringSync();

    expect(pubspec, contains('local_auth: ^3.0.2'));
    expect(manifest, contains('android.permission.USE_BIOMETRIC'));
    expect(activity, contains('FlutterFragmentActivity'));
    expect(lightStyles, contains('Theme.AppCompat.DayNight.NoActionBar'));
    expect(darkStyles, contains('Theme.AppCompat.DayNight.NoActionBar'));
    expect(infoPlist, contains('<key>NSFaceIDUsageDescription</key>'));
    expect(authenticator, contains('biometricOnly: false'));
    expect(authenticator, contains('persistAcrossBackgrounding: true'));
    expect(authenticator, isNot(contains('AuthenticationOptions')));
    expect(authenticator, isNot(contains('stickyAuth')));
  });

  test('daily reminders use minimal permissions and local-time scheduling', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final resourceKeep = File(
      'android/app/src/main/res/raw/keep.xml',
    ).readAsStringSync();
    final gateway = File(
      'lib/core/services/reminder_notification_gateway.dart',
    ).readAsStringSync();
    final iosDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final androidActivity = File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/MainActivity.kt',
    ).readAsStringSync();

    expect(pubspec, contains('flutter_local_notifications: ^22.2.0'));
    expect(pubspec, isNot(contains('flutter_timezone:')));
    expect(pubspec, contains('timezone: ^0.11.1'));
    expect(manifest, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    expect(manifest, contains('ScheduledNotificationReceiver'));
    expect(manifest, contains('ScheduledNotificationBootReceiver'));
    expect(manifest, isNot(contains('android.permission.USE_EXACT_ALARM')));
    expect(
      manifest,
      isNot(contains('android.permission.SCHEDULE_EXACT_ALARM')),
    );
    expect(gradle, contains('desugar_jdk_libs:2.1.4'));
    expect(resourceKeep, contains('@mipmap/ic_launcher'));
    expect(gateway, contains('requestNotificationsPermission'));
    expect(gateway, contains('zonedSchedule'));
    expect(gateway, contains('DateTimeComponents.time'));
    expect(gateway, contains('AndroidScheduleMode.inexactAllowWhileIdle'));
    expect(gateway, isNot(contains('periodicallyShow')));
    expect(
      iosDelegate,
      contains('UNUserNotificationCenter.current().delegate'),
    );
    expect(iosDelegate, contains('expense_tracker/device_timezone'));
    expect(androidActivity, contains('expense_tracker/device_timezone'));
  });

  test('native recovery queue is bounded by count and age', () async {
    final receiver = await File(
      'android/app/src/main/kotlin/com/calvin/expense_tracker/'
      'NotificationQueueReceiver.kt',
    ).readAsString();

    expect(receiver, contains('MAX_QUEUE_SIZE = 50'));
    expect(
      receiver,
      contains('MAX_QUEUE_AGE_MILLIS = 24L * 60L * 60L * 1000L'),
    );
    expect(receiver, contains('receivedAt - MAX_QUEUE_AGE_MILLIS'));
  });
}
