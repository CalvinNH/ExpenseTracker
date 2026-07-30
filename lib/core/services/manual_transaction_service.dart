import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/transaction.dart';

/// The only presentation-facing mutation boundary for manual transactions.
/// Database methods remain atomic and rebuild linked ledger balances safely.
class ManualTransactionService {
  ManualTransactionService({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  Future<int> create(Transaction transaction) =>
      _database.createTransaction(transaction);

  Future<int> update(Transaction transaction) =>
      _database.updateTransaction(transaction);

  Future<int> delete(int transactionId) =>
      _database.deleteTransaction(transactionId);
}
