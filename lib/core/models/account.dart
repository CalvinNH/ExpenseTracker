import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';

class Account {
  Account({
    this.id,
    String? displayName,
    String? bankName,
    this.institutionId,
    this.accountType = AccountType.unknown,
    this.lastFour,
    this.upiHandle,
    this.sourcePackageHint,
    this.isProvisional = false,
    int? openingBalanceMinor,
    double? currentBalance,
    this.currencyCode = 'INR',
    DateTime? createdAt,
  }) : assert(
         displayName != null || bankName != null,
         'displayName or legacy bankName is required',
       ),
       displayName = displayName ?? bankName!,
       openingBalanceMinor =
           openingBalanceMinor ?? majorToMinor(currentBalance ?? 0),
       currentBalance =
           currentBalance ?? minorToMajor(openingBalanceMinor ?? 0),
       createdAt = createdAt ?? DateTime.now();

  final int? id;
  final String displayName;
  final String? institutionId;
  final AccountType accountType;
  final String? lastFour;
  final String? upiHandle;
  final String? sourcePackageHint;
  final bool isProvisional;
  final int openingBalanceMinor;
  final String currencyCode;
  final DateTime createdAt;

  /// Compatibility value used by the existing UI until it moves to minor units.
  final double currentBalance;

  /// Compatibility alias for screens and ingestion matching.
  String get bankName => displayName;

  Account copyWith({
    int? id,
    String? displayName,
    String? bankName,
    String? institutionId,
    AccountType? accountType,
    String? lastFour,
    String? upiHandle,
    String? sourcePackageHint,
    bool? isProvisional,
    int? openingBalanceMinor,
    double? currentBalance,
    String? currencyCode,
    DateTime? createdAt,
  }) {
    return Account(
      id: id ?? this.id,
      displayName: displayName ?? bankName ?? this.displayName,
      institutionId: institutionId ?? this.institutionId,
      accountType: accountType ?? this.accountType,
      lastFour: lastFour ?? this.lastFour,
      upiHandle: upiHandle ?? this.upiHandle,
      sourcePackageHint: sourcePackageHint ?? this.sourcePackageHint,
      isProvisional: isProvisional ?? this.isProvisional,
      openingBalanceMinor: openingBalanceMinor ?? this.openingBalanceMinor,
      currentBalance: currentBalance ?? this.currentBalance,
      currencyCode: currencyCode ?? this.currencyCode,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'display_name': displayName,
      'institution_id': institutionId,
      'account_type': accountType.storageValue,
      'last_four': lastFour,
      'upi_handle': upiHandle,
      'source_package_hint': sourcePackageHint,
      'is_provisional': isProvisional ? 1 : 0,
      'opening_balance_minor': openingBalanceMinor,
      'currency_code': currencyCode,
      'created_at': createdAt.toIso8601String(),
      'current_balance': currentBalance,
    };
  }

  factory Account.fromMap(Map<String, Object?> map) {
    return Account(
      id: map['id'] as int?,
      displayName: (map['display_name'] ?? map['bank_name']) as String,
      institutionId: map['institution_id'] as String?,
      accountType: AccountType.fromStorage(
        map['account_type'] as String? ?? AccountType.unknown.storageValue,
      ),
      lastFour: map['last_four'] as String?,
      upiHandle: map['upi_handle'] as String?,
      sourcePackageHint: map['source_package_hint'] as String?,
      isProvisional: (map['is_provisional'] as int? ?? 0) == 1,
      openingBalanceMinor:
          map['opening_balance_minor'] as int? ??
          majorToMinor((map['current_balance'] as num).toDouble()),
      currentBalance: (map['current_balance'] as num).toDouble(),
      currencyCode: map['currency_code'] as String? ?? 'INR',
      createdAt: map['created_at'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(map['created_at'] as String),
    );
  }

  static AccountType inferTypeFromDisplayName(String name) {
    final normalized = name.toLowerCase();
    if (normalized.contains('credit') ||
        RegExp(r'\bcc\b').hasMatch(normalized)) {
      return AccountType.creditCard;
    }
    if (normalized.contains('debit card')) return AccountType.debitCard;
    if (normalized.contains('wallet') ||
        normalized.contains('paytm') ||
        normalized.contains('gpay') ||
        normalized.contains('phonepe')) {
      return AccountType.wallet;
    }
    if (normalized.contains('cash')) return AccountType.cash;
    if (normalized.contains('bank') ||
        normalized.contains('savings') ||
        normalized.contains('current') ||
        normalized.contains('account')) {
      return AccountType.bankAccount;
    }
    return AccountType.unknown;
  }

  static String? extractSafeTrailingFour(String name) {
    final match = RegExp(r'(?:\b|[*xX.])(\d{4})\s*$').firstMatch(name.trim());
    return match?.group(1);
  }
}
