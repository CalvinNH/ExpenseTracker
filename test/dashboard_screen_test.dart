import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/services/financial_lifecycle_service.dart';
import 'package:expense_tracker/features/dashboard/presentation/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  setUpAll(() {
    // Initialize FFI for sqflite
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.databaseName = inMemoryDatabasePath;
  });

  setUp(() async {
    // Reset the singleton database connection
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  testWidgets(
    'Dashboard Screen builds and shows empty state for transactions',
    (WidgetTester tester) async {
      // Seed database with an account but no transactions
      final db = AppDatabase.instance;
      await db.createAccount(
        Account(bankName: 'HDFC Bank', currentBalance: 12000.50),
      );

      // Build the DashboardScreen inside a MaterialApp
      await tester.pumpWidget(const MaterialApp(home: DashboardScreen()));

      // Trigger initial frame (shows loading spinner)
      await tester.pump();

      // Since AppDatabase uses real FFI database calls on the real event loop,
      // we must yield using tester.runAsync to let them complete.
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });

      // Pump again to render the loaded state
      await tester.pump();

      // Verify page header
      expect(find.text('Home'), findsOneWidget);

      // Verify total balance card data
      expect(find.text('TOTAL BALANCE'), findsOneWidget);
      expect(find.text('₹ 12000.50'), findsOneWidget);

      // Verify empty state messages
      expect(find.text('₹ 0.00'), findsOneWidget);
      expect(find.text('No transactions detected yet.'), findsOneWidget);
    },
  );

  testWidgets(
    'Dashboard Screen search button filters transactions by merchant description',
    (WidgetTester tester) async {
      final db = AppDatabase.instance;
      final accountId = await db.createAccount(
        Account(bankName: 'HDFC Bank', currentBalance: 12000.50),
      );

      // Seed transactions
      await db.createTransaction(
        Transaction(
          amount: 450.0,
          type: TransactionType.debit,
          timestamp: DateTime.now(),
          merchant: 'Zomato Food Delivery',
          category: 'Food & Dining',
          accountId: accountId,
        ),
      );

      await db.createTransaction(
        Transaction(
          amount: 150.0,
          type: TransactionType.debit,
          timestamp: DateTime.now(),
          merchant: 'Uber Ride',
          category: 'Transport',
          accountId: accountId,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: DashboardScreen()));

      await tester.pump();
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      // Verify both are present initially
      expect(find.text('Zomato Food Delivery'), findsOneWidget);
      expect(find.text('Uber Ride'), findsOneWidget);

      // Tap search icon in header
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();

      // Verify search field is displayed
      expect(find.byType(TextField), findsOneWidget);

      // Enter query 'zom'
      await tester.enterText(find.byType(TextField), 'zom');
      await tester.pumpAndSettle();

      // Verify list is filtered
      expect(find.text('Zomato Food Delivery'), findsOneWidget);
      expect(find.text('Uber Ride'), findsNothing);

      // Enter query 'uber'
      await tester.enterText(find.byType(TextField), 'uber');
      await tester.pumpAndSettle();

      // Verify list is filtered
      expect(find.text('Uber Ride'), findsOneWidget);
      expect(find.text('Zomato Food Delivery'), findsNothing);

      // Tap close button
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      // Verify default list is restored
      expect(find.text('Zomato Food Delivery'), findsOneWidget);
      expect(find.text('Uber Ride'), findsOneWidget);
    },
  );

  testWidgets('Dashboard shows gross, refunds and net separately',
      (WidgetTester tester) async {
    final accountId = await AppDatabase.instance.createAccount(
      Account(bankName: 'SBI', currentBalance: 5000),
    );
    final lifecycle = FinancialLifecycleService();
    final group = await lifecycle.recordPurchase(
      accountId: accountId,
      amountMinor: 100000,
      occurredAt: DateTime.now(),
      category: 'Shopping',
      merchant: 'Amazon',
    );
    await lifecycle.recordRefund(
      originalGroupId: group,
      destinationAccountId: accountId,
      amountMinor: 40000,
      occurredAt: DateTime.now(),
      status: FinancialEventStatus.completed,
      linkConfidence: .99,
    );

    await tester.pumpWidget(const MaterialApp(home: DashboardScreen()));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(find.byKey(const Key('dashboard-gross-expenses')), findsOneWidget);
    expect(find.text('Gross ₹1000'), findsOneWidget);
    expect(find.text('Refunds ₹400'), findsOneWidget);
    expect(find.text('₹ 600.00'), findsOneWidget);
  });
}
