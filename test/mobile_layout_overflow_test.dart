import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/analytics/presentation/analytics_screen.dart';
import 'package:expense_tracker/features/dashboard/presentation/dashboard_screen.dart';
import 'package:expense_tracker/features/transactions/presentation/add_edit_transaction_sheet.dart';
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

  tearDown(() => AppDatabase.instance.close());

  Future<void> seed() async {
    final accountId = await AppDatabase.instance.createAccount(
      Account(
        bankName: 'State Bank of India Savings Account',
        currentBalance: 100000,
      ),
    );
    await AppDatabase.instance.createTransaction(
      Transaction(
        amount: 12345678.90,
        type: TransactionType.debit,
        timestamp: DateTime.now(),
        merchant: 'A merchant with a deliberately long display name',
        category: 'Food & Dining',
        accountId: accountId,
      ),
    );
  }

  for (final screen in <String, Widget>{
    'dashboard': const DashboardScreen(),
    'analytics': const AnalyticsScreen(),
  }.entries) {
    testWidgets('${screen.key} has no horizontal overflow at phone width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await seed();
      await tester.pumpWidget(MaterialApp(home: screen.value));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'transaction selectors do not overflow with long account and large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await AppDatabase.instance.createAccount(
        Account(
          displayName: 'State Bank of India Corporate Salary Account',
          accountType: AccountType.bankAccount,
          lastFour: '4455',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: const Scaffold(body: AddEditTransactionSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      expect(find.text('Merchant or Description'), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(
        find.textContaining('State Bank of India Corporate'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('transaction-category-selector')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('transaction-account-selector')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('transaction-date-selector')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
