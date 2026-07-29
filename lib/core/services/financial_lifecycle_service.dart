import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';

class FinancialLifecycleService {
  FinancialLifecycleService({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  Future<int> recordPurchase({
    required int accountId,
    required int amountMinor,
    required DateTime occurredAt,
    required String category,
    String? merchant,
  }) async {
    _requirePositive(amountMinor);
    await _requireAccount(accountId);
    final now = DateTime.now().toUtc();
    final groupId = await _database.createTransactionGroup(
      TransactionGroup(
        groupType: TransactionGroupType.purchase,
        merchantNormalized: merchant,
        category: category,
        originalAmountMinor: amountMinor,
        refundableAmountMinor: amountMinor,
        netExpenseMinor: amountMinor,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _database.createLedgerEntry(
      LedgerEntry(
        transactionGroupId: groupId,
        accountId: accountId,
        direction: FinancialDirection.debit,
        amountMinor: amountMinor,
        currencyCode: 'INR',
        occurredAt: occurredAt,
        eventRole: LedgerEventRole.primary,
        category: category,
        merchant: merchant,
        createdAt: now,
      ),
    );
    return groupId;
  }

  Future<int> recordRefund({
    int? originalGroupId,
    required int destinationAccountId,
    required int amountMinor,
    required DateTime occurredAt,
    required FinancialEventStatus status,
    double linkConfidence = 1,
  }) async {
    _requirePositive(amountMinor);
    await _requireAccount(destinationAccountId);

    if (originalGroupId == null || linkConfidence < .85) {
      return _recordUnmatchedRefund(
        destinationAccountId: destinationAccountId,
        amountMinor: amountMinor,
        occurredAt: occurredAt,
        status: status,
      );
    }

    final group = await _database.getTransactionGroup(originalGroupId);
    if (group == null || group.originalAmountMinor == null) {
      return _recordUnmatchedRefund(
        destinationAccountId: destinationAccountId,
        amountMinor: amountMinor,
        occurredAt: occurredAt,
        status: status,
      );
    }
    if (status != FinancialEventStatus.completed) {
      return originalGroupId;
    }

    final completed = group.completedRefundAmountMinor + amountMinor;
    final refundable =
        group.refundableAmountMinor ?? group.originalAmountMinor!;
    final excess = completed > refundable;
    await _database.updateTransactionGroupLifecycle(
      transactionGroupId: originalGroupId,
      groupType: completed == refundable
          ? TransactionGroupType.purchaseRefund
          : TransactionGroupType.partialRefund,
      completedRefundAmountMinor: completed,
      netExpenseMinor: group.originalAmountMinor! - completed,
      isInconsistent: group.isInconsistent || excess,
      inconsistencyReason: excess
          ? 'completed_refund_exceeds_refundable_amount'
          : group.inconsistencyReason,
    );
    final category = _safeRefundCategory(group.category);
    await _database.createLedgerEntry(
      LedgerEntry(
        transactionGroupId: originalGroupId,
        accountId: destinationAccountId,
        direction: FinancialDirection.credit,
        amountMinor: amountMinor,
        currencyCode: 'INR',
        occurredAt: occurredAt,
        eventRole: LedgerEventRole.refund,
        category: category,
        merchant: group.merchantNormalized,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return originalGroupId;
  }

  Future<int> _recordUnmatchedRefund({
    required int destinationAccountId,
    required int amountMinor,
    required DateTime occurredAt,
    required FinancialEventStatus status,
  }) async {
    final now = DateTime.now().toUtc();
    final completed = status == FinancialEventStatus.completed;
    final groupId = await _database.createTransactionGroup(
      TransactionGroup(
        groupType: TransactionGroupType.unknown,
        completedRefundAmountMinor: completed ? amountMinor : 0,
        netExpenseMinor: completed ? -amountMinor : 0,
        isInconsistent: true,
        inconsistencyReason: 'refund_original_purchase_unidentified',
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (completed) {
      await _database.createLedgerEntry(
        LedgerEntry(
          transactionGroupId: groupId,
          accountId: destinationAccountId,
          direction: FinancialDirection.credit,
          amountMinor: amountMinor,
          currencyCode: 'INR',
          occurredAt: occurredAt,
          eventRole: LedgerEventRole.refund,
          createdAt: now,
        ),
      );
    }
    return groupId;
  }

  Future<void> recordReversal({
    required int originalGroupId,
    required DateTime occurredAt,
    required FinancialEventStatus status,
  }) async {
    if (status != FinancialEventStatus.completed) return;
    final group = await _database.getTransactionGroup(originalGroupId);
    if (group == null) {
      throw StateError('Original transaction group not found.');
    }
    final entries = await _database.getLedgerEntriesByGroup(originalGroupId);
    final original = entries
        .where((entry) => entry.eventRole == LedgerEventRole.primary)
        .firstOrNull;
    if (original == null) {
      throw StateError('Original ledger effect not found.');
    }
    await _database.createLedgerEntry(
      LedgerEntry(
        transactionGroupId: originalGroupId,
        accountId: original.accountId,
        direction: original.direction == FinancialDirection.debit
            ? FinancialDirection.credit
            : FinancialDirection.debit,
        amountMinor: original.amountMinor,
        currencyCode: original.currencyCode,
        occurredAt: occurredAt,
        eventRole: LedgerEventRole.reversal,
        category: original.category,
        merchant: original.merchant,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    await _database.updateTransactionGroupLifecycle(
      transactionGroupId: originalGroupId,
      groupType: TransactionGroupType.reversal,
      completedRefundAmountMinor: group.completedRefundAmountMinor,
      netExpenseMinor: 0,
      isInconsistent: group.isInconsistent,
      inconsistencyReason: group.inconsistencyReason,
    );
  }

  Future<int> recordTransfer({
    required int sourceAccountId,
    int? destinationAccountId,
    required int amountMinor,
    required DateTime occurredAt,
    required TransferType transferType,
    String? merchant,
  }) async {
    _requirePositive(amountMinor);
    final source = await _requireAccount(sourceAccountId);
    final destination = destinationAccountId == null
        ? null
        : await _requireAccount(destinationAccountId);
    _validateTransferAccounts(transferType, source, destination);

    final now = DateTime.now().toUtc();
    final groupId = await _database.createTransactionGroup(
      TransactionGroup(
        groupType: TransactionGroupType.transfer,
        transferType: transferType,
        merchantNormalized: merchant,
        netExpenseMinor: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _database.createLedgerEntry(
      LedgerEntry(
        transactionGroupId: groupId,
        accountId: sourceAccountId,
        direction: FinancialDirection.debit,
        amountMinor: amountMinor,
        currencyCode: 'INR',
        occurredAt: occurredAt,
        eventRole: LedgerEventRole.primary,
        merchant: merchant,
        createdAt: now,
      ),
    );
    if (destinationAccountId != null) {
      await _database.createLedgerEntry(
        LedgerEntry(
          transactionGroupId: groupId,
          accountId: destinationAccountId,
          direction: FinancialDirection.credit,
          amountMinor: amountMinor,
          currencyCode: 'INR',
          occurredAt: occurredAt,
          eventRole: LedgerEventRole.adjustment,
          merchant: merchant,
          createdAt: now,
        ),
      );
    }
    return groupId;
  }

  void _validateTransferAccounts(
    TransferType transferType,
    Account source,
    Account? destination,
  ) {
    if (transferType != TransferType.external && destination == null) {
      throw ArgumentError('This transfer type requires a destination account.');
    }
    if (transferType == TransferType.walletLoad &&
        destination?.accountType != AccountType.wallet) {
      throw ArgumentError('Wallet load destination must be a wallet.');
    }
    if (transferType == TransferType.walletWithdrawal &&
        source.accountType != AccountType.wallet) {
      throw ArgumentError('Wallet withdrawal source must be a wallet.');
    }
    if (transferType == TransferType.creditCardPayment &&
        destination?.accountType != AccountType.creditCard) {
      throw ArgumentError(
        'Credit-card payment destination must be a credit-card account.',
      );
    }
  }

  Future<Account> _requireAccount(int accountId) async {
    final account = await _database.getAccount(accountId);
    if (account == null) throw StateError('Account $accountId not found.');
    return account;
  }

  void _requirePositive(int amountMinor) {
    if (amountMinor <= 0) {
      throw ArgumentError.value(
        amountMinor,
        'amountMinor',
        'Amount must be positive.',
      );
    }
  }

  String? _safeRefundCategory(String? category) {
    if (category?.trim().toLowerCase() == 'salary') return null;
    return category;
  }
}
