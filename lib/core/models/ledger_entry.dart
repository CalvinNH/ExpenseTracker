import 'package:expense_tracker/core/models/financial_enums.dart';

class LedgerEntry {
  const LedgerEntry({
    this.id,
    this.transactionGroupId,
    this.parsedFinancialEventId,
    required this.accountId,
    required this.direction,
    required this.amountMinor,
    required this.currencyCode,
    required this.occurredAt,
    required this.eventRole,
    this.category,
    this.merchant,
    this.isProvisional = false,
    required this.createdAt,
  });

  final int? id;
  final int? transactionGroupId;
  final int? parsedFinancialEventId;
  final int accountId;
  final FinancialDirection direction;
  final int amountMinor;
  final String currencyCode;
  final DateTime occurredAt;
  final LedgerEventRole eventRole;
  final String? category;
  final String? merchant;
  final bool isProvisional;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'transaction_group_id': transactionGroupId,
    'parsed_financial_event_id': parsedFinancialEventId,
    'account_id': accountId,
    'direction': direction.storageValue,
    'amount_minor': amountMinor,
    'currency_code': currencyCode,
    'occurred_at': occurredAt.toIso8601String(),
    'event_role': eventRole.storageValue,
    'category': category,
    'merchant': merchant,
    'is_provisional': isProvisional ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory LedgerEntry.fromMap(Map<String, Object?> map) {
    return LedgerEntry(
      id: map['id'] as int?,
      transactionGroupId: map['transaction_group_id'] as int?,
      parsedFinancialEventId: map['parsed_financial_event_id'] as int?,
      accountId: map['account_id'] as int,
      direction: FinancialDirection.fromStorage(map['direction'] as String),
      amountMinor: map['amount_minor'] as int,
      currencyCode: map['currency_code'] as String,
      occurredAt: DateTime.parse(map['occurred_at'] as String),
      eventRole: LedgerEventRole.fromStorage(map['event_role'] as String),
      category: map['category'] as String?,
      merchant: map['merchant'] as String?,
      isProvisional: (map['is_provisional'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
