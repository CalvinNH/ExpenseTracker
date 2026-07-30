import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';

class FinancialSummary {
  const FinancialSummary({
    this.grossExpensesMinor = 0,
    this.completedRefundsMinor = 0,
    this.netExpensesMinor = 0,
    this.incomeMinor = 0,
    this.cashbackMinor = 0,
    this.feesMinor = 0,
    this.transfersMinor = 0,
    this.accountBalancesMinor = 0,
  });

  final int grossExpensesMinor;
  final int completedRefundsMinor;
  final int netExpensesMinor;
  final int incomeMinor;
  final int cashbackMinor;
  final int feesMinor;
  final int transfersMinor;
  final int accountBalancesMinor;
}

class CategoryFinancialSummary {
  const CategoryFinancialSummary({
    required this.category,
    required this.grossSpendMinor,
    required this.refundsMinor,
  });

  final String category;
  final int grossSpendMinor;
  final int refundsMinor;
  int get netSpendMinor => grossSpendMinor - refundsMinor;
}

class AccountLedgerMovement {
  const AccountLedgerMovement({
    required this.entry,
    required this.accountName,
    this.groupType,
  });

  final LedgerEntry entry;
  final String accountName;
  final TransactionGroupType? groupType;
}

class TransactionStory {
  const TransactionStory({
    required this.group,
    required this.movements,
    required this.informationalEvents,
  });

  final TransactionGroup group;
  final List<AccountLedgerMovement> movements;
  final List<ParsedFinancialEvent> informationalEvents;
}
