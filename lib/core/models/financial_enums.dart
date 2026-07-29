T enumFromStorage<T extends Enum>(
  List<T> values,
  String value, {
  required T fallback,
}) {
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  return fallback;
}

extension EnumStorageValue on Enum {
  String get storageValue => name;
}

enum FinancialDirection {
  debit,
  credit,
  none,
  unknown;

  static FinancialDirection fromStorage(String value) =>
      enumFromStorage(values, value, fallback: FinancialDirection.unknown);
}

enum FinancialEventType {
  purchase,
  transfer,
  refund,
  reversal,
  cashback,
  withdrawal,
  deposit,
  fee,
  authorization,
  balanceAlert,
  income,
  unknown;

  static FinancialEventType fromStorage(String value) =>
      enumFromStorage(values, value, fallback: FinancialEventType.unknown);
}

enum FinancialEventStatus {
  initiated,
  pending,
  completed,
  failed,
  declined,
  reversed,
  unknown;

  static FinancialEventStatus fromStorage(String value) =>
      enumFromStorage(values, value, fallback: FinancialEventStatus.unknown);
}

enum ParseDecision {
  autoPost,
  provisional,
  retainOnly,
  ignored;

  static ParseDecision fromStorage(String value) =>
      enumFromStorage(values, value, fallback: ParseDecision.retainOnly);
}

enum AccountType {
  bankAccount,
  creditCard,
  debitCard,
  wallet,
  cash,
  unknown;

  static AccountType fromStorage(String value) =>
      enumFromStorage(values, value, fallback: AccountType.unknown);
}

enum RawNotificationProcessingState {
  retained,
  parsed,
  posted,
  failed,
  ignored;

  static RawNotificationProcessingState fromStorage(String value) =>
      enumFromStorage(
        values,
        value,
        fallback: RawNotificationProcessingState.retained,
      );
}

enum TransactionGroupType {
  purchase,
  purchaseRefund,
  partialRefund,
  reversal,
  transfer,
  authorizationCompletion,
  cashbackRelated,
  unknown;

  static TransactionGroupType fromStorage(String value) =>
      enumFromStorage(values, value, fallback: TransactionGroupType.unknown);
}

enum TransferType {
  ownAccount,
  external,
  walletLoad,
  walletWithdrawal,
  creditCardPayment,
  unknown;

  static TransferType fromStorage(String value) =>
      enumFromStorage(values, value, fallback: TransferType.unknown);
}

enum LedgerEventRole {
  primary,
  refund,
  reversal,
  fee,
  adjustment,
  unknown;

  static LedgerEventRole fromStorage(String value) =>
      enumFromStorage(values, value, fallback: LedgerEventRole.unknown);
}
