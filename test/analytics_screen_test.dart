import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/analytics/presentation/analytics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.databaseName = inMemoryDatabasePath;
  });

  setUp(() async {
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  testWidgets('Analytics Screen displays visual charts and tab switcher correctly',
      (WidgetTester tester) async {
    final db = AppDatabase.instance;

    // Seed database with multiple accounts of different types
    final hdfcCcId = await db.createAccount(const Account(
      bankName: 'HDFC Platinum CC',
      currentBalance: -5000.0,
    ));

    final hdfcSavingsId = await db.createAccount(const Account(
      bankName: 'HDFC Savings',
      currentBalance: 50000.0,
    ));

    // Seed debit transactions
    // 1. Food expense on HDFC Platinum CC
    await db.createTransaction(Transaction(
      amount: 1200.0,
      type: TransactionType.debit,
      timestamp: DateTime.now(),
      merchant: 'Restaurant',
      category: 'Food & Dining',
      accountId: hdfcCcId,
    ));

    // 2. Shopping expense on HDFC Savings
    await db.createTransaction(Transaction(
      amount: 4500.0,
      type: TransactionType.debit,
      timestamp: DateTime.now(),
      merchant: 'Store',
      category: 'Shopping',
      accountId: hdfcSavingsId,
    ));

    // Build the AnalyticsScreen inside a MaterialApp
    await tester.pumpWidget(
      const MaterialApp(
        home: AnalyticsScreen(),
      ),
    );

    // Trigger initial frame (shows loading spinner)
    await tester.pump();

    // Yield to the real event loop to allow FFI database tasks to complete
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 200));
    });

    // Re-pump widget to render loaded state
    await tester.pump();

    // Verify Title
    expect(find.text('Analytics'), findsOneWidget);

    // Verify Total Spent (1200 + 4500 = 5700)
    expect(find.text('TOTAL SPENT'), findsOneWidget);
    expect(find.text('₹ 5700.00'), findsOneWidget);

    // Verify Tab Switcher is present
    expect(find.text('Categories'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);

    // Verify category legend info
    expect(find.text('Food & Dining'), findsOneWidget);
    expect(find.text('Shopping'), findsOneWidget);
  });

  testWidgets('Analytics Screen filters transactions dynamically based on period selection',
      (WidgetTester tester) async {
    final db = AppDatabase.instance;

    final accountId = await db.createAccount(const Account(
      bankName: 'HDFC Savings',
      currentBalance: 50000.0,
    ));

    final now = DateTime.now();

    // 1. Expense today (500.0)
    await db.createTransaction(Transaction(
      amount: 500.0,
      type: TransactionType.debit,
      timestamp: now,
      merchant: 'Today Merchant',
      category: 'Food & Dining',
      accountId: accountId,
    ));

    // 2. Expense 2 months ago (1000.0)
    await db.createTransaction(Transaction(
      amount: 1000.0,
      type: TransactionType.debit,
      timestamp: DateTime(now.year, now.month - 2, now.day),
      merchant: 'Two Months Ago Merchant',
      category: 'Shopping',
      accountId: accountId,
    ));

    // 3. Expense 6 months ago (2000.0)
    await db.createTransaction(Transaction(
      amount: 2000.0,
      type: TransactionType.debit,
      timestamp: DateTime(now.year, now.month - 6, now.day),
      merchant: 'Six Months Ago Merchant',
      category: 'Entertainment',
      accountId: accountId,
    ));

    await tester.pumpWidget(
      const MaterialApp(
        home: AnalyticsScreen(),
      ),
    );

    await tester.pump();

    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 200));
    });

    await tester.pump();

    // Under default 'This Month', only today's transaction is displayed: 500.0 (shown in total card and list tile)
    expect(find.text('₹ 500.00'), findsNWidgets(2));

    // Tap on the filter button to open PopupMenu
    await tester.tap(find.text('This Month'));
    await tester.pumpAndSettle();

    // Select 'Last 3 months'
    await tester.tap(find.text('Last 3 months').last);
    await tester.pumpAndSettle();

    // Under 'Last 3 months', today + 2 months ago = 1500.0 (shown in total card and HDFC Savings list item)
    expect(find.text('₹ 1500.00'), findsNWidgets(2));

    // Tap on the filter button again
    await tester.tap(find.text('Last 3 months'));
    await tester.pumpAndSettle();

    // Select 'Last year'
    await tester.tap(find.text('Last year').last);
    await tester.pumpAndSettle();

    // Under 'Last year', all transactions are calculated = 3500.0 (shown in total card and HDFC Savings list item)
    expect(find.text('₹ 3500.00'), findsNWidgets(2));
  });
}
