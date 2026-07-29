import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/services/financial_lifecycle_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late FinancialLifecycleService lifecycle;
  final purchaseAt = DateTime.utc(2026, 1, 15);

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

  Future<int> account(
    String name,
    AccountType type, {
    int openingBalanceMinor = 100000,
  }) {
    return AppDatabase.instance.createAccount(
      Account(
        displayName: name,
        accountType: type,
        openingBalanceMinor: openingBalanceMinor,
      ),
    );
  }

  Future<int> shoppingPurchase(int accountId, {int amount = 100000}) {
    return lifecycle.recordPurchase(
      accountId: accountId,
      amountMinor: amount,
      occurredAt: purchaseAt,
      category: 'Shopping',
      merchant: 'Amazon',
    );
  }

  for (final refundToWallet in [false, true]) {
    test('database contract: INR 2000 purchase and INR 1000 refund '
        '${refundToWallet ? 'to wallet' : 'to original account'}', () async {
      final sbi = await account(
        'SBI',
        AccountType.bankAccount,
        openingBalanceMinor: 500000,
      );
      final wallet = await account(
        'Amazon Pay Wallet',
        AccountType.wallet,
        openingBalanceMinor: 0,
      );
      final destination = refundToWallet ? wallet : sbi;
      final groupId = await shoppingPurchase(sbi, amount: 200000);

      await lifecycle.recordRefund(
        originalGroupId: groupId,
        destinationAccountId: destination,
        amountMinor: 100000,
        occurredAt: purchaseAt.add(const Duration(days: 2)),
        status: FinancialEventStatus.completed,
        linkConfidence: .96,
      );

      final db = await AppDatabase.instance.database;
      final groupRows = await db.query(
        AppDatabase.tableTransactionGroups,
        where: 'id = ?',
        whereArgs: [groupId],
      );
      expect(groupRows, hasLength(1));
      expect(groupRows.single['original_amount_minor'], 200000);
      expect(groupRows.single['refundable_amount_minor'], 200000);
      expect(groupRows.single['completed_refund_amount_minor'], 100000);
      expect(groupRows.single['net_expense_minor'], 100000);
      expect(groupRows.single['category'], 'Shopping');
      expect(groupRows.single['is_inconsistent'], 0);

      final ledgerRows = await db.query(
        AppDatabase.tableLedgerEntries,
        where: 'transaction_group_id = ?',
        whereArgs: [groupId],
        orderBy: 'id ASC',
      );
      expect(ledgerRows, hasLength(2));
      expect(ledgerRows.first['direction'], 'debit');
      expect(ledgerRows.first['event_role'], 'primary');
      expect(ledgerRows.first['amount_minor'], 200000);
      expect(ledgerRows.first['account_id'], sbi);
      expect(ledgerRows.last['direction'], 'credit');
      expect(ledgerRows.last['event_role'], 'refund');
      expect(ledgerRows.last['amount_minor'], 100000);
      expect(ledgerRows.last['account_id'], destination);
      expect(ledgerRows.last['category'], 'Shopping');

      final entries = await AppDatabase.instance.getLedgerEntriesByGroup(
        groupId,
      );
      expect(entries.first.countsAsIncome, isFalse);
      expect(entries.last.countsAsIncome, isFalse);
      expect(
        await db.query(AppDatabase.tableTransactions),
        isEmpty,
        reason: 'lifecycle ledger credits are not legacy income rows',
      );

      expect(
        (await AppDatabase.instance.getAccount(destination))?.currentBalance,
        refundToWallet ? 1000 : 4000,
      );
      if (refundToWallet) {
        expect(
          (await AppDatabase.instance.getAccount(sbi))?.currentBalance,
          3000,
        );
      }
    });
  }

  test('refund category is inherited only after a confident link', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final wallet = await account('Wallet', AccountType.wallet);
    final originalGroupId = await shoppingPurchase(sbi, amount: 200000);

    final reviewGroupId = await lifecycle.recordRefund(
      originalGroupId: originalGroupId,
      destinationAccountId: wallet,
      amountMinor: 100000,
      occurredAt: purchaseAt.add(const Duration(days: 1)),
      status: FinancialEventStatus.completed,
      linkConfidence: .70,
    );

    expect(reviewGroupId, isNot(originalGroupId));
    final original = await AppDatabase.instance.getTransactionGroup(
      originalGroupId,
    );
    expect(original?.completedRefundAmountMinor, 0);
    expect(original?.netExpenseMinor, 200000);
    final reviewRefund = (await AppDatabase.instance.getLedgerEntriesByGroup(
      reviewGroupId,
    )).single;
    expect(reviewRefund.category, isNull);
    expect(reviewRefund.countsAsIncome, isFalse);
    expect(
      (await AppDatabase.instance.getTransactionGroup(
        reviewGroupId,
      ))?.isInconsistent,
      isTrue,
    );
  });

  test('full refund to original account offsets purchase', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final groupId = await shoppingPurchase(sbi);

    await lifecycle.recordRefund(
      originalGroupId: groupId,
      destinationAccountId: sbi,
      amountMinor: 100000,
      occurredAt: purchaseAt.add(const Duration(days: 2)),
      status: FinancialEventStatus.completed,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.originalAmountMinor, 100000);
    expect(group?.completedRefundAmountMinor, 100000);
    expect(group?.netExpenseMinor, 0);
    expect(group?.category, 'Shopping');
    final entries = await AppDatabase.instance.getLedgerEntriesByGroup(groupId);
    expect(entries, hasLength(2));
    expect(entries.map((entry) => entry.direction), [
      FinancialDirection.debit,
      FinancialDirection.credit,
    ]);
    expect(entries.last.category, 'Shopping');
  });

  test('full refund can settle into a different wallet', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final wallet = await account(
      'Amazon Pay Wallet',
      AccountType.wallet,
      openingBalanceMinor: 0,
    );
    final groupId = await shoppingPurchase(sbi);

    await lifecycle.recordRefund(
      originalGroupId: groupId,
      destinationAccountId: wallet,
      amountMinor: 100000,
      occurredAt: purchaseAt.add(const Duration(days: 2)),
      status: FinancialEventStatus.completed,
    );

    final entries = await AppDatabase.instance.getLedgerEntriesByGroup(groupId);
    expect(entries, hasLength(2));
    expect(entries.first.accountId, sbi);
    expect(entries.first.direction, FinancialDirection.debit);
    expect(entries.last.accountId, wallet);
    expect(entries.last.direction, FinancialDirection.credit);
    final signedTotal = entries.fold<int>(
      0,
      (total, entry) =>
          total +
          (entry.direction == FinancialDirection.credit
              ? entry.amountMinor
              : -entry.amountMinor),
    );
    expect(signedTotal, 0);
    expect(
      (await AppDatabase.instance.getTransactionGroup(
        groupId,
      ))?.netExpenseMinor,
      0,
    );
  });

  test('partial refund leaves the unrefunded amount as net spend', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final groupId = await shoppingPurchase(sbi);

    await lifecycle.recordRefund(
      originalGroupId: groupId,
      destinationAccountId: sbi,
      amountMinor: 40000,
      occurredAt: purchaseAt.add(const Duration(days: 1)),
      status: FinancialEventStatus.completed,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.groupType, TransactionGroupType.partialRefund);
    expect(group?.completedRefundAmountMinor, 40000);
    expect(group?.netExpenseMinor, 60000);
  });

  test('multiple partial refunds accumulate and cannot hide excess', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final groupId = await shoppingPurchase(sbi);

    for (final amount in [25000, 35000, 50000]) {
      await lifecycle.recordRefund(
        originalGroupId: groupId,
        destinationAccountId: sbi,
        amountMinor: amount,
        occurredAt: purchaseAt.add(Duration(days: amount ~/ 10000)),
        status: FinancialEventStatus.completed,
      );
    }

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.completedRefundAmountMinor, 110000);
    expect(group?.netExpenseMinor, -10000);
    expect(group?.isInconsistent, isTrue);
    expect(
      group?.inconsistencyReason,
      'completed_refund_exceeds_refundable_amount',
    );
    expect(
      await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
      hasLength(4),
      reason: 'the excess event is preserved, not silently discarded',
    );
  });

  test(
    'refund initiated but not completed creates no ledger movement',
    () async {
      final sbi = await account('SBI', AccountType.bankAccount);
      final wallet = await account('Amazon Pay Wallet', AccountType.wallet);
      final groupId = await shoppingPurchase(sbi);

      await lifecycle.recordRefund(
        originalGroupId: groupId,
        destinationAccountId: wallet,
        amountMinor: 100000,
        occurredAt: purchaseAt.add(const Duration(days: 1)),
        status: FinancialEventStatus.initiated,
      );

      final group = await AppDatabase.instance.getTransactionGroup(groupId);
      expect(group?.completedRefundAmountMinor, 0);
      expect(group?.netExpenseMinor, 100000);
      expect(
        await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
        hasLength(1),
      );
    },
  );

  test(
    'completed reversal preserves and offsets both ledger effects',
    () async {
      final sbi = await account('SBI', AccountType.bankAccount);
      final groupId = await shoppingPurchase(sbi);

      await lifecycle.recordReversal(
        originalGroupId: groupId,
        occurredAt: purchaseAt.add(const Duration(hours: 2)),
        status: FinancialEventStatus.completed,
      );

      final entries = await AppDatabase.instance.getLedgerEntriesByGroup(
        groupId,
      );
      expect(entries, hasLength(2));
      expect(entries.first.eventRole, LedgerEventRole.primary);
      expect(entries.last.eventRole, LedgerEventRole.reversal);
      expect(entries.last.direction, FinancialDirection.credit);
      expect(
        (await AppDatabase.instance.getTransactionGroup(
          groupId,
        ))?.netExpenseMinor,
        0,
      );
    },
  );

  test('own-account transfer changes balances but not expense', () async {
    final source = await account('SBI', AccountType.bankAccount);
    final destination = await account(
      'HDFC',
      AccountType.bankAccount,
      openingBalanceMinor: 0,
    );

    final groupId = await lifecycle.recordTransfer(
      sourceAccountId: source,
      destinationAccountId: destination,
      amountMinor: 40000,
      occurredAt: purchaseAt,
      transferType: TransferType.ownAccount,
    );

    expect(
      (await AppDatabase.instance.getTransactionGroup(
        groupId,
      ))?.netExpenseMinor,
      0,
    );
    expect(
      (await AppDatabase.instance.getAccount(source))?.currentBalance,
      600,
    );
    expect(
      (await AppDatabase.instance.getAccount(destination))?.currentBalance,
      400,
    );
  });

  test('wallet load is a balanced transfer, not spending', () async {
    final bank = await account('SBI', AccountType.bankAccount);
    final wallet = await account(
      'Amazon Pay Wallet',
      AccountType.wallet,
      openingBalanceMinor: 0,
    );

    final groupId = await lifecycle.recordTransfer(
      sourceAccountId: bank,
      destinationAccountId: wallet,
      amountMinor: 30000,
      occurredAt: purchaseAt,
      transferType: TransferType.walletLoad,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.transferType, TransferType.walletLoad);
    expect(group?.netExpenseMinor, 0);
    expect(
      await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
      hasLength(2),
    );
  });

  test('wallet withdrawal returns value to a bank without spending', () async {
    final wallet = await account('Wallet', AccountType.wallet);
    final bank = await account(
      'SBI',
      AccountType.bankAccount,
      openingBalanceMinor: 0,
    );

    final groupId = await lifecycle.recordTransfer(
      sourceAccountId: wallet,
      destinationAccountId: bank,
      amountMinor: 20000,
      occurredAt: purchaseAt,
      transferType: TransferType.walletWithdrawal,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.transferType, TransferType.walletWithdrawal);
    expect(group?.netExpenseMinor, 0);
    expect(
      await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
      hasLength(2),
    );
  });

  test('external transfer records the asset outflow without expense', () async {
    final bank = await account('SBI', AccountType.bankAccount);

    final groupId = await lifecycle.recordTransfer(
      sourceAccountId: bank,
      amountMinor: 15000,
      occurredAt: purchaseAt,
      transferType: TransferType.external,
      merchant: 'Family transfer',
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.transferType, TransferType.external);
    expect(group?.netExpenseMinor, 0);
    expect(
      await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
      hasLength(1),
    );
  });

  test(
    'credit-card bill payment reduces bank asset and card liability',
    () async {
      final bank = await account('SBI', AccountType.bankAccount);
      final card = await account(
        'SBI Credit Card',
        AccountType.creditCard,
        openingBalanceMinor: -50000,
      );

      final groupId = await lifecycle.recordTransfer(
        sourceAccountId: bank,
        destinationAccountId: card,
        amountMinor: 50000,
        occurredAt: purchaseAt,
        transferType: TransferType.creditCardPayment,
      );

      expect(
        (await AppDatabase.instance.getTransactionGroup(
          groupId,
        ))?.netExpenseMinor,
        0,
      );
      expect(
        (await AppDatabase.instance.getAccount(bank))?.currentBalance,
        500,
      );
      expect((await AppDatabase.instance.getAccount(card))?.currentBalance, 0);
    },
  );

  test('refund without original purchase is retained for review', () async {
    final wallet = await account('Wallet', AccountType.wallet);

    final groupId = await lifecycle.recordRefund(
      destinationAccountId: wallet,
      amountMinor: 10000,
      occurredAt: purchaseAt,
      status: FinancialEventStatus.completed,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.isInconsistent, isTrue);
    expect(group?.inconsistencyReason, 'refund_original_purchase_unidentified');
    final refund = (await AppDatabase.instance.getLedgerEntriesByGroup(
      groupId,
    )).single;
    expect(refund.category, isNull);
    expect(refund.category, isNot('Salary'));
  });

  test('refund in a later month still links to original purchase', () async {
    final sbi = await account('SBI', AccountType.bankAccount);
    final groupId = await shoppingPurchase(sbi);

    await lifecycle.recordRefund(
      originalGroupId: groupId,
      destinationAccountId: sbi,
      amountMinor: 40000,
      occurredAt: DateTime.utc(2026, 3, 2),
      status: FinancialEventStatus.completed,
    );

    final group = await AppDatabase.instance.getTransactionGroup(groupId);
    expect(group?.completedRefundAmountMinor, 40000);
    expect(group?.netExpenseMinor, 60000);
    expect(
      await AppDatabase.instance.getLedgerEntriesByGroup(groupId),
      hasLength(2),
    );
  });
}
