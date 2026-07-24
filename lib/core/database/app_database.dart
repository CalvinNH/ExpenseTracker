import 'dart:async';
import 'dart:io';

import 'package:expense_tracker/core/database/database_migrator.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/security/security_key_manager.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' as sqflite_global;
import 'package:sqflite_sqlcipher/sqflite.dart' hide Transaction;

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static String databaseName = 'expense_tracker.db';
  static const _databaseVersion = 1;

  static const tableAccounts = 'accounts';
  static const tableTransactions = 'transactions';

  Database? _database;
  Future<Database>? _databaseFuture;
  String? _passphrase;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null && existing.isOpen) {
      return existing;
    }

    try {
      _databaseFuture ??= _initDatabase();
      _database = await _databaseFuture;
      return _database!;
    } catch (e) {
      _databaseFuture = null;
      _database = null;
      rethrow;
    }
  }

  Future<Database> _initDatabase() async {
    if (databaseName == inMemoryDatabasePath) {
      // In-memory databases (used by tests) bypass encryption entirely.
      // Top-level openDatabase of sqflite_sqlcipher bypasses the overridden
      // databaseFactory, so we must invoke the true global databaseFactory.openDatabase
      // to ensure tests run against the FFI test database factory.
      return sqflite_global.databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: _databaseVersion,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, databaseName);

    // Ensure the databases directory exists (fixes open_failed exception)
    await Directory(dbPath).create(recursive: true);

    // Retrieve or generate the Keystore-backed encryption passphrase
    _passphrase = await SecurityKeyManager.instance.getOrCreateDatabaseKey();

    // Handle migration from plaintext → encrypted for existing users
    await DatabaseMigrator.instance.migrateIfNeeded(path, _passphrase!);

    return openDatabase(
      path,
      password: _passphrase,
      version: _databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $tableAccounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bank_name TEXT NOT NULL,
        current_balance REAL NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableTransactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        amount REAL NOT NULL,
        type TEXT NOT NULL CHECK(type IN ('credit', 'debit')),
        timestamp TEXT NOT NULL,
        merchant TEXT NOT NULL,
        category TEXT NOT NULL,
        account_id INTEGER NOT NULL,
        FOREIGN KEY (account_id) REFERENCES $tableAccounts (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Reserved for future schema migrations.
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
    }
    _database = null;
    _databaseFuture = null;
  }

  // --- Accounts CRUD ---

  Future<int> createAccount(Account account) async {
    final db = await database;
    return db.insert(tableAccounts, account.toMap());
  }

  Future<Account?> getAccount(int id) async {
    final db = await database;
    final rows = await db.query(
      tableAccounts,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return Account.fromMap(rows.first);
  }

  Future<List<Account>> getAllAccounts() async {
    final db = await database;
    final rows = await db.query(
      tableAccounts,
      orderBy: 'bank_name ASC',
    );

    return rows.map(Account.fromMap).toList();
  }

  Future<int> updateAccount(Account account) async {
    if (account.id == null) {
      throw ArgumentError('Cannot update an account without an id.');
    }

    final db = await database;
    return db.update(
      tableAccounts,
      account.toMap(),
      where: 'id = ?',
      whereArgs: [account.id],
    );
  }

  Future<int> deleteAccount(int id) async {
    final db = await database;
    return db.delete(
      tableAccounts,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // --- Transactions CRUD ---

  Future<int> createTransaction(Transaction transaction) async {
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert(tableTransactions, transaction.toMap());

      // Update account balance
      final accountRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [transaction.accountId],
        limit: 1,
      );

      if (accountRows.isNotEmpty) {
        final currentBalance = (accountRows.first['current_balance'] as num).toDouble();
        final change = transaction.type == TransactionType.credit ? transaction.amount : -transaction.amount;
        final newBalance = currentBalance + change;
        await txn.update(
          tableAccounts,
          {'current_balance': newBalance},
          where: 'id = ?',
          whereArgs: [transaction.accountId],
        );
      }

      return id;
    });
  }

  /// Returns true if a transaction with the same amount, type, account, and merchant
  /// was recorded within [window] of now. Used ONLY by the notification
  /// ingestion path to suppress duplicate alerts for the same underlying
  /// transaction (e.g. re-posted or updated notifications).
  Future<bool> hasRecentDuplicate({
    required double amount,
    required TransactionType type,
    required int accountId,
    String? merchant,
    Duration window = const Duration(seconds: 30),
  }) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(window).toIso8601String();
    
    if (merchant != null && merchant.isNotEmpty && merchant != 'Unknown') {
      final rows = await db.query(
        tableTransactions,
        columns: ['id'],
        where: 'amount = ? AND type = ? AND account_id = ? AND merchant = ? AND timestamp >= ?',
        whereArgs: [amount, type.value, accountId, merchant, cutoff],
        limit: 1,
      );
      if (rows.isNotEmpty) return true;
    }

    final rows = await db.query(
      tableTransactions,
      columns: ['id'],
      where: 'amount = ? AND type = ? AND account_id = ? AND timestamp >= ?',
      whereArgs: [amount, type.value, accountId, cutoff],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<Transaction?> getTransaction(int id) async {
    final db = await database;
    final rows = await db.query(
      tableTransactions,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return Transaction.fromMap(rows.first);
  }

  Future<List<Transaction>> getAllTransactions() async {
    final db = await database;
    final rows = await db.query(
      tableTransactions,
      orderBy: 'timestamp DESC',
    );

    return rows.map(Transaction.fromMap).toList();
  }

  Future<List<Transaction>> getTransactionsByAccountId(int accountId) async {
    final db = await database;
    final rows = await db.query(
      tableTransactions,
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'timestamp DESC',
    );

    return rows.map(Transaction.fromMap).toList();
  }

  Future<int> updateTransaction(Transaction transaction) async {
    if (transaction.id == null) {
      throw ArgumentError('Cannot update a transaction without an id.');
    }

    final db = await database;
    return db.transaction((txn) async {
      // 1. Get the old transaction
      final oldTxnRows = await txn.query(
        tableTransactions,
        where: 'id = ?',
        whereArgs: [transaction.id],
        limit: 1,
      );
      if (oldTxnRows.isEmpty) {
        throw StateError('Transaction with id ${transaction.id} not found.');
      }
      final oldTxn = Transaction.fromMap(oldTxnRows.first);

      // 2. Revert old transaction balance from old account
      final oldAccRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [oldTxn.accountId],
        limit: 1,
      );
      if (oldAccRows.isNotEmpty) {
        final currentBalance = (oldAccRows.first['current_balance'] as num).toDouble();
        final revertChange = oldTxn.type == TransactionType.credit ? -oldTxn.amount : oldTxn.amount;
        await txn.update(
          tableAccounts,
          {'current_balance': currentBalance + revertChange},
          where: 'id = ?',
          whereArgs: [oldTxn.accountId],
        );
      }

      // 3. Apply new transaction balance to new/current account
      final newAccRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [transaction.accountId],
        limit: 1,
      );
      if (newAccRows.isNotEmpty) {
        double currentBalance;
        if (transaction.accountId == oldTxn.accountId) {
          final updatedAccRows = await txn.query(
            tableAccounts,
            where: 'id = ?',
            whereArgs: [transaction.accountId],
            limit: 1,
          );
          currentBalance = (updatedAccRows.first['current_balance'] as num).toDouble();
        } else {
          currentBalance = (newAccRows.first['current_balance'] as num).toDouble();
        }

        final applyChange = transaction.type == TransactionType.credit ? transaction.amount : -transaction.amount;
        await txn.update(
          tableAccounts,
          {'current_balance': currentBalance + applyChange},
          where: 'id = ?',
          whereArgs: [transaction.accountId],
        );
      }

      // 4. Update the transaction row
      return txn.update(
        tableTransactions,
        transaction.toMap(),
        where: 'id = ?',
        whereArgs: [transaction.id],
      );
    });
  }

  Future<int> deleteTransaction(int id) async {
    final db = await database;
    return db.transaction((txn) async {
      // 1. Get the old transaction
      final oldTxnRows = await txn.query(
        tableTransactions,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (oldTxnRows.isEmpty) {
        return 0;
      }
      final oldTxn = Transaction.fromMap(oldTxnRows.first);

      // 2. Revert old transaction balance from account
      final accRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [oldTxn.accountId],
        limit: 1,
      );
      if (accRows.isNotEmpty) {
        final currentBalance = (accRows.first['current_balance'] as num).toDouble();
        final revertChange = oldTxn.type == TransactionType.credit ? -oldTxn.amount : oldTxn.amount;
        await txn.update(
          tableAccounts,
          {'current_balance': currentBalance + revertChange},
          where: 'id = ?',
          whereArgs: [oldTxn.accountId],
        );
      }

      // 3. Delete the transaction
      return txn.delete(
        tableTransactions,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  Future<double> getTotalBalance() async {
    final db = await database;
    final result = await db.rawQuery('SELECT SUM(current_balance) as total FROM $tableAccounts');
    final value = result.first['total'];
    return (value as num?)?.toDouble() ?? 0.0;
  }

  Future<List<Transaction>> getRecentTransactions({int limit = 10}) async {
    final db = await database;
    final rows = await db.query(
      tableTransactions,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map(Transaction.fromMap).toList();
  }

  Future<Map<String, double>> getMonthlyExpensesByCategory() async {
    final db = await database;
    final currentMonthStr = DateTime.now().toIso8601String().substring(0, 7); // YYYY-MM
    
    final result = await db.query(
      tableTransactions,
      columns: ['category', 'SUM(amount) as total'],
      where: "type = 'debit' AND strftime('%Y-%m', timestamp) = ?",
      whereArgs: [currentMonthStr],
      groupBy: 'category',
    );

    final Map<String, double> categoryTotals = {};
    for (final row in result) {
      final category = row['category'] as String;
      final total = (row['total'] as num).toDouble();
      categoryTotals[category] = total;
    }
    return categoryTotals;
  }
}
