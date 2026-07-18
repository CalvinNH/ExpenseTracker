class Account {
  const Account({
    this.id,
    required this.bankName,
    required this.currentBalance,
  });

  final int? id;
  final String bankName;
  final double currentBalance;

  Account copyWith({
    int? id,
    String? bankName,
    double? currentBalance,
  }) {
    return Account(
      id: id ?? this.id,
      bankName: bankName ?? this.bankName,
      currentBalance: currentBalance ?? this.currentBalance,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'bank_name': bankName,
      'current_balance': currentBalance,
    };
  }

  factory Account.fromMap(Map<String, Object?> map) {
    return Account(
      id: map['id'] as int?,
      bankName: map['bank_name'] as String,
      currentBalance: (map['current_balance'] as num).toDouble(),
    );
  }
}
