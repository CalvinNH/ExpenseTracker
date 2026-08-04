// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;
import 'package:expense_tracker/features/onboarding/presentation/onboarding_screen.dart';
import 'package:expense_tracker/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDatabase.databaseName = inMemoryDatabasePath;
  });
  const MethodChannel sqfliteChannel = MethodChannel(
    'plugins.flutter.dev/sqflite',
  );
  const MethodChannel notificationChannel = MethodChannel(
    'x-slayer/notification_listener_service',
  );
  const MethodChannel secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    AppDatabase.databaseName = inMemoryDatabasePath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sqfliteChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'getDatabasesPath') {
            return 'mock_db_path';
          }
          if (methodCall.method == 'openDatabase') {
            return 1;
          }
          if (methodCall.method == 'query') {
            return <dynamic>[];
          }
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'isPermissionGranted') {
            return false;
          }
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (
          MethodCall methodCall,
        ) async {
          // Return null for reads (no key exists) — triggers in-memory fallback
          if (methodCall.method == 'read') {
            return null;
          }
          // Accept writes silently
          if (methodCall.method == 'write') {
            return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sqfliteChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  testWidgets('App onboarding screen smoke test', (WidgetTester tester) async {
    // Set a larger screen size so all ListView elements are built and visible
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Build our app and trigger a frame.
    await tester.pumpWidget(const ExpenseTrackerApp());

    // Resolve the encrypted database initialization and startup privacy
    // cleanup without relying on a single machine-speed-dependent delay.
    for (var attempt = 0;
        attempt < 20 && find.byType(OnboardingScreen).evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
    }

    // Verify that onboarding screen shows the welcome message.
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.textContaining('Welcome to your'), findsOneWidget);
  });
}
