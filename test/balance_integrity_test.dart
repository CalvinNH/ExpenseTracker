import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    AppDatabase.databaseName = inMemoryDatabasePath;
  });

  setUp(() async {
    await AppDatabase.instance.close();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  group('Ledger Sync — Balance Integrity', () {
    test('Insert debit reduces balance, delete restores it', () async {
      final db = AppDatabase.instance;

      // Create account with known starting balance
      final accountId = await db.createAccount(
        const Account(bankName: 'Test Bank', currentBalance: 10000.00),
      );

      // Verify starting balance
      var account = await db.getAccount(accountId);
      expect(account!.currentBalance, 10000.00);

      // Insert a ₹500 debit
      final txnId = await db.createTransaction(
        Transaction(
          amount: 500.00,
          type: TransactionType.debit,
          timestamp: DateTime.now(),
          merchant: 'Test Merchant',
          category: 'Food',
          accountId: accountId,
        ),
      );

      // Verify balance decreased
      account = await db.getAccount(accountId);
      expect(account!.currentBalance, 9500.00);

      // Delete the transaction
      await db.deleteTransaction(txnId);

      // Verify balance is restored exactly
      account = await db.getAccount(accountId);
      expect(account!.currentBalance, 10000.00);
    });

    test(
      'Insert credit increases balance, update amount adjusts correctly, delete restores',
      () async {
        final db = AppDatabase.instance;

        final accountId = await db.createAccount(
          const Account(bankName: 'Test Bank', currentBalance: 10000.00),
        );

        // Insert a ₹2,000 credit
        final txnId = await db.createTransaction(
          Transaction(
            amount: 2000.00,
            type: TransactionType.credit,
            timestamp: DateTime.now(),
            merchant: 'Salary',
            category: 'Miscellaneous',
            accountId: accountId,
          ),
        );

        var account = await db.getAccount(accountId);
        expect(account!.currentBalance, 12000.00);

        // Update that credit to ₹3,000
        final existingTxn = await db.getTransaction(txnId);
        await db.updateTransaction(existingTxn!.copyWith(amount: 3000.00));

        account = await db.getAccount(accountId);
        expect(account!.currentBalance, 13000.00);

        // Delete it — balance must return to exactly 10,000
        await db.deleteTransaction(txnId);

        account = await db.getAccount(accountId);
        expect(account!.currentBalance, 10000.00);
      },
    );

    test('Update type from debit to credit swings balance correctly', () async {
      final db = AppDatabase.instance;

      final accountId = await db.createAccount(
        const Account(bankName: 'Test Bank', currentBalance: 10000.00),
      );

      // Insert a ₹1,000 debit → balance = 9,000
      final txnId = await db.createTransaction(
        Transaction(
          amount: 1000.00,
          type: TransactionType.debit,
          timestamp: DateTime.now(),
          merchant: 'Shop',
          category: 'Shopping',
          accountId: accountId,
        ),
      );

      var account = await db.getAccount(accountId);
      expect(account!.currentBalance, 9000.00);

      // Change it to a credit → revert -1000 then apply +1000 → net = 10000 + 1000 = 11000
      final existingTxn = await db.getTransaction(txnId);
      await db.updateTransaction(
        existingTxn!.copyWith(type: TransactionType.credit),
      );

      account = await db.getAccount(accountId);
      expect(account!.currentBalance, 11000.00);

      // Delete → back to 10,000
      await db.deleteTransaction(txnId);

      account = await db.getAccount(accountId);
      expect(account!.currentBalance, 10000.00);
    });
  });
}
