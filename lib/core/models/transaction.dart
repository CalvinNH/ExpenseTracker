enum TransactionType {
  credit,
  debit;

  String get value => name;

  static TransactionType fromString(String value) {
    return TransactionType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw ArgumentError('Invalid transaction type: $value'),
    );
  }
}

class Transaction {
  const Transaction({
    this.id,
    required this.amount,
    required this.type,
    required this.timestamp,
    required this.merchant,
    required this.category,
    required this.accountId,
  });

  final int? id;
  final double amount;
  final TransactionType type;
  final DateTime timestamp;
  final String merchant;
  final String category;
  final int accountId;

  Transaction copyWith({
    int? id,
    double? amount,
    TransactionType? type,
    DateTime? timestamp,
    String? merchant,
    String? category,
    int? accountId,
  }) {
    return Transaction(
      id: id ?? this.id,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      merchant: merchant ?? this.merchant,
      category: category ?? this.category,
      accountId: accountId ?? this.accountId,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'amount': amount,
      'type': type.value,
      'timestamp': timestamp.toIso8601String(),
      'merchant': merchant,
      'category': category,
      'account_id': accountId,
    };
  }

  factory Transaction.fromMap(Map<String, Object?> map) {
    return Transaction(
      id: map['id'] as int?,
      amount: (map['amount'] as num).toDouble(),
      type: TransactionType.fromString(map['type'] as String),
      timestamp: DateTime.parse(map['timestamp'] as String),
      merchant: map['merchant'] as String,
      category: map['category'] as String,
      accountId: map['account_id'] as int,
    );
  }
}
