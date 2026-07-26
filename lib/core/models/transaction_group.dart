import 'package:expense_tracker/core/models/financial_enums.dart';

class TransactionGroup {
  const TransactionGroup({
    this.id,
    required this.groupType,
    this.merchantNormalized,
    this.category,
    this.originalAmountMinor,
    this.completedRefundAmountMinor = 0,
    required this.netExpenseMinor,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final TransactionGroupType groupType;
  final String? merchantNormalized;
  final String? category;
  final int? originalAmountMinor;
  final int completedRefundAmountMinor;
  final int netExpenseMinor;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'group_type': groupType.storageValue,
    'merchant_normalized': merchantNormalized,
    'category': category,
    'original_amount_minor': originalAmountMinor,
    'completed_refund_amount_minor': completedRefundAmountMinor,
    'net_expense_minor': netExpenseMinor,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory TransactionGroup.fromMap(Map<String, Object?> map) {
    return TransactionGroup(
      id: map['id'] as int?,
      groupType: TransactionGroupType.fromStorage(map['group_type'] as String),
      merchantNormalized: map['merchant_normalized'] as String?,
      category: map['category'] as String?,
      originalAmountMinor: map['original_amount_minor'] as int?,
      completedRefundAmountMinor: map['completed_refund_amount_minor'] as int,
      netExpenseMinor: map['net_expense_minor'] as int,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
