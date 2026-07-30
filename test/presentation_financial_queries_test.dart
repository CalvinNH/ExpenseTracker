import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/services/financial_lifecycle_service.dart';
import 'package:expense_tracker/core/services/manual_transaction_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  late FinancialLifecycleService lifecycle;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await AppDatabase.instance.close();
    AppDatabase.databaseName = inMemoryDatabasePath;
    AppDatabase.databasePathOverrideForTesting = null;
    lifecycle = FinancialLifecycleService();
  });

  tearDown(() => AppDatabase.instance.close());

  Future<int> account(String name, AccountType type, {int opening = 0}) =>
      AppDatabase.instance.createAccount(
        Account(
          displayName: name,
          accountType: type,
          openingBalanceMinor: opening,
        ),
      );

  test(
    'gross, refunds, net and category analytics are lifecycle aware',
    () async {
      final bank = await account(
        'SBI',
        AccountType.bankAccount,
        opening: 500000,
      );
      final wallet = await account('Amazon Pay', AccountType.wallet);
      final purchase = await lifecycle.recordPurchase(
        accountId: bank,
        amountMinor: 200000,
        occurredAt: DateTime.utc(2026, 1, 20),
        category: 'Shopping',
        merchant: 'Amazon',
      );
      await lifecycle.recordRefund(
        originalGroupId: purchase,
        destinationAccountId: wallet,
        amountMinor: 100000,
        occurredAt: DateTime.utc(2026, 2, 3),
        status: FinancialEventStatus.completed,
        linkConfidence: .98,
      );

      final all = await AppDatabase.instance.getFinancialSummary();
      expect(all.grossExpensesMinor, 200000);
      expect(all.completedRefundsMinor, 100000);
      expect(all.netExpensesMinor, 100000);
      expect(all.incomeMinor, 0);

      final january = await AppDatabase.instance.getFinancialSummary(
        start: DateTime.utc(2026, 1),
        end: DateTime.utc(2026, 2),
      );
      expect(january.grossExpensesMinor, 200000);
      expect(january.completedRefundsMinor, 0);
      expect(january.netExpensesMinor, 200000);

      final february = await AppDatabase.instance.getFinancialSummary(
        start: DateTime.utc(2026, 2),
        end: DateTime.utc(2026, 3),
      );
      expect(february.grossExpensesMinor, 0);
      expect(february.completedRefundsMinor, 100000);
      expect(february.netExpensesMinor, -100000);

      final categories = await AppDatabase.instance
          .getCategoryFinancialSummaries();
      final shopping = categories.singleWhere(
        (row) => row.category == 'Shopping',
      );
      expect(shopping.grossSpendMinor, 200000);
      expect(shopping.refundsMinor, 100000);
      expect(shopping.netSpendMinor, 100000);
    },
  );

  test(
    'transfers are separate and every account movement stays visible',
    () async {
      final bank = await account(
        'SBI',
        AccountType.bankAccount,
        opening: 300000,
      );
      final wallet = await account('Wallet', AccountType.wallet);
      final group = await lifecycle.recordTransfer(
        sourceAccountId: bank,
        destinationAccountId: wallet,
        amountMinor: 75000,
        occurredAt: DateTime.utc(2026, 4, 1),
        transferType: TransferType.walletLoad,
      );

      final summary = await AppDatabase.instance.getFinancialSummary();
      expect(summary.grossExpensesMinor, 0);
      expect(summary.netExpensesMinor, 0);
      expect(summary.incomeMinor, 0);
      expect(summary.transfersMinor, 75000);

      final movements = await AppDatabase.instance.getAccountLedgerMovements();
      expect(movements, hasLength(2));
      expect(
        movements.map((m) => m.entry.direction),
        containsAll([FinancialDirection.debit, FinancialDirection.credit]),
      );
      expect(
        movements.every((m) => m.entry.transactionGroupId == group),
        isTrue,
      );
      final stories = await AppDatabase.instance.getTransactionStories();
      expect(stories.single.movements, hasLength(2));
    },
  );

  test(
    'manual create edit and delete remain balanced and are projected',
    () async {
      final bank = await account(
        'Manual Bank',
        AccountType.bankAccount,
        opening: 100000,
      );
      final service = ManualTransactionService();
      final id = await service.create(
        Transaction(
          amount: 250,
          type: TransactionType.debit,
          timestamp: DateTime.utc(2026, 5, 1),
          merchant: 'Manual purchase',
          category: 'Shopping',
          accountId: bank,
        ),
      );
      expect(
        (await AppDatabase.instance.getFinancialSummary()).netExpensesMinor,
        25000,
      );
      await service.update(
        (await AppDatabase.instance.getTransaction(id))!.copyWith(amount: 400),
      );
      expect(
        (await AppDatabase.instance.getAccount(bank))!.currentBalance,
        600,
      );
      expect(
        (await AppDatabase.instance.getFinancialSummary()).netExpensesMinor,
        40000,
      );
      await service.delete(id);
      expect(
        (await AppDatabase.instance.getAccount(bank))!.currentBalance,
        1000,
      );
      expect(
        (await AppDatabase.instance.getFinancialSummary()).netExpensesMinor,
        0,
      );
    },
  );
}
