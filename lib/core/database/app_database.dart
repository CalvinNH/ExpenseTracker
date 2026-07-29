import 'dart:async';
import 'dart:io';

import 'package:expense_tracker/core/database/database_migrator.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';
import 'package:expense_tracker/core/security/security_key_manager.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart' as sqflite_global;
import 'package:sqflite_sqlcipher/sqflite.dart' hide Transaction;

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static String databaseName = 'expense_tracker.db';
  static String? databasePathOverrideForTesting;
  static const databaseVersion = 6;

  static const tableAccounts = 'accounts';
  static const tableTransactions = 'transactions';
  static const tableRawNotificationEvents = 'raw_notification_events';
  static const tableParsedFinancialEvents = 'parsed_financial_events';
  static const tableTransactionGroups = 'transaction_groups';
  static const tableLedgerEntries = 'ledger_entries';
  static const tableAccountMerges = 'account_merges';
  static const tableParsedEventLedgerLinks = 'parsed_event_ledger_links';
  static const tableParsedEventGroupLinks = 'parsed_event_group_links';

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
    final testPath = databasePathOverrideForTesting;
    if (testPath != null) {
      return sqflite_global.databaseFactory.openDatabase(
        testPath,
        options: OpenDatabaseOptions(
          version: databaseVersion,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }
    if (databaseName == inMemoryDatabasePath) {
      // In-memory databases (used by tests) bypass encryption entirely.
      // Top-level openDatabase of sqflite_sqlcipher bypasses the overridden
      // databaseFactory, so we must invoke the true global databaseFactory.openDatabase
      // to ensure tests run against the FFI test database factory.
      return sqflite_global.databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: databaseVersion,
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
      version: databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createVersion2Schema(db);
    await _createAccountMergesTable(db);
  }

  Future<void> _createVersion2Schema(Database db) async {
    await db.execute('''
      CREATE TABLE $tableAccounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        display_name TEXT NOT NULL,
        institution_id TEXT,
        account_type TEXT NOT NULL DEFAULT 'unknown',
        last_four TEXT,
        upi_handle TEXT,
        source_package_hint TEXT,
        is_provisional INTEGER NOT NULL DEFAULT 0 CHECK(is_provisional IN (0, 1)),
        opening_balance_minor INTEGER NOT NULL DEFAULT 0,
        currency_code TEXT NOT NULL DEFAULT 'INR',
        created_at TEXT NOT NULL,
        current_balance REAL NOT NULL DEFAULT 0
      )
    ''');

    await _createLegacyTransactionsTable(db);
    await _createDomainTablesAndIndexes(db);
  }

  Future<void> _createLegacyTransactionsTable(Database db) async {
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
    var version = oldVersion;
    while (version < newVersion) {
      switch (version) {
        case 1:
          await _upgradeFrom1To2(db);
        case 2:
          await _upgradeFrom2To3(db);
        case 3:
          await _createAccountMergesTable(db);
        case 4:
          await _upgradeFrom4To5(db);
        case 5:
          await _upgradeFrom5To6(db);
        default:
          throw StateError('No database migration from version $version.');
      }
      version++;
    }
  }

  Future<void> _upgradeFrom1To2(Database db) async {
    await db.execute(
      'ALTER TABLE $tableAccounts RENAME COLUMN bank_name TO display_name',
    );
    await db.execute(
      'ALTER TABLE $tableAccounts ADD COLUMN institution_id TEXT',
    );
    await db.execute(
      "ALTER TABLE $tableAccounts ADD COLUMN account_type TEXT NOT NULL DEFAULT 'unknown'",
    );
    await db.execute('ALTER TABLE $tableAccounts ADD COLUMN last_four TEXT');
    await db.execute('ALTER TABLE $tableAccounts ADD COLUMN upi_handle TEXT');
    await db.execute(
      'ALTER TABLE $tableAccounts ADD COLUMN source_package_hint TEXT',
    );
    await db.execute(
      'ALTER TABLE $tableAccounts ADD COLUMN is_provisional INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableAccounts ADD COLUMN opening_balance_minor INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      "ALTER TABLE $tableAccounts ADD COLUMN currency_code TEXT NOT NULL DEFAULT 'INR'",
    );
    await db.execute(
      "ALTER TABLE $tableAccounts ADD COLUMN created_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z'",
    );

    // v1 current_balance already contains every legacy transaction's balance
    // effect. It becomes the v2 opening baseline while the legacy transaction
    // rows remain untouched, so migration never applies those effects twice.
    final accounts = await db.query(tableAccounts);
    final migratedAt = DateTime.now().toUtc().toIso8601String();
    for (final row in accounts) {
      final displayName = row['display_name'] as String;
      final currentBalance = (row['current_balance'] as num).toDouble();
      await db.update(
        tableAccounts,
        {
          'account_type': Account.inferTypeFromDisplayName(
            displayName,
          ).storageValue,
          'last_four': Account.extractSafeTrailingFour(displayName),
          'opening_balance_minor': majorToMinor(currentBalance),
          'created_at': migratedAt,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }

    await _createDomainTablesAndIndexes(db);
  }

  Future<void> _upgradeFrom2To3(Database db) async {
    final rawColumns = await db.rawQuery(
      'PRAGMA table_info($tableRawNotificationEvents)',
    );
    if (!rawColumns.any((row) => row['name'] == 'supersedes_event_id')) {
      await db.execute(
        'ALTER TABLE $tableRawNotificationEvents '
        'ADD COLUMN supersedes_event_id INTEGER '
        'REFERENCES $tableRawNotificationEvents (id) ON DELETE SET NULL',
      );
    }
    final ledgerColumns = await db.rawQuery(
      'PRAGMA table_info($tableLedgerEntries)',
    );
    if (!ledgerColumns.any((row) => row['name'] == 'legacy_transaction_id')) {
      await db.execute(
        'ALTER TABLE $tableLedgerEntries '
        'ADD COLUMN legacy_transaction_id INTEGER '
        'REFERENCES $tableTransactions (id) ON DELETE CASCADE',
      );
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_ledger_legacy_transaction '
      'ON $tableLedgerEntries (legacy_transaction_id) '
      'WHERE legacy_transaction_id IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_supersedes '
      'ON $tableRawNotificationEvents (supersedes_event_id)',
    );
  }

  Future<void> _upgradeFrom4To5(Database db) async {
    if (await _tableExists(db, tableRawNotificationEvents)) {
      await _addColumnIfMissing(
        db,
        tableRawNotificationEvents,
        'exact_duplicate_of_event_id',
        'INTEGER',
      );
      await _addColumnIfMissing(
        db,
        tableRawNotificationEvents,
        'duplicate_rationale',
        'TEXT',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_raw_exact_duplicate '
        'ON $tableRawNotificationEvents (exact_duplicate_of_event_id)',
      );
    }
    if (await _tableExists(db, tableParsedFinancialEvents)) {
      await _addColumnIfMissing(
        db,
        tableParsedFinancialEvents,
        'payment_rail',
        'TEXT',
      );
      await _addColumnIfMissing(
        db,
        tableParsedFinancialEvents,
        'ledger_duplicate_confidence',
        'REAL NOT NULL DEFAULT 0',
      );
      await _addColumnIfMissing(
        db,
        tableParsedFinancialEvents,
        'ledger_duplicate_rationale',
        'TEXT',
      );
    }
    if (await _tableExists(db, tableParsedFinancialEvents) &&
        await _tableExists(db, tableLedgerEntries) &&
        await _tableExists(db, tableTransactionGroups)) {
      await _createEventLinkTables(db);
    }
  }

  Future<void> _upgradeFrom5To6(Database db) async {
    if (!await _tableExists(db, tableTransactionGroups)) return;
    await _addColumnIfMissing(
      db,
      tableTransactionGroups,
      'refundable_amount_minor',
      'INTEGER',
    );
    await _addColumnIfMissing(
      db,
      tableTransactionGroups,
      'transfer_type',
      'TEXT',
    );
    await _addColumnIfMissing(
      db,
      tableTransactionGroups,
      'is_inconsistent',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfMissing(
      db,
      tableTransactionGroups,
      'inconsistency_reason',
      'TEXT',
    );
    await db.execute(
      'UPDATE $tableTransactionGroups '
      'SET refundable_amount_minor = original_amount_minor '
      'WHERE refundable_amount_minor IS NULL',
    );
  }

  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: [table],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String declaration,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (!columns.any((row) => row['name'] == column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $declaration');
    }
  }

  Future<void> _createAccountMergesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableAccountMerges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provisional_account_id INTEGER NOT NULL,
        confirmed_account_id INTEGER NOT NULL,
        provisional_display_name TEXT NOT NULL,
        provisional_opening_balance_minor INTEGER NOT NULL,
        merged_at TEXT NOT NULL,
        CHECK(provisional_account_id != confirmed_account_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_account_merges_provisional '
      'ON $tableAccountMerges (provisional_account_id)',
    );
  }

  Future<void> _createDomainTablesAndIndexes(Database db) async {
    await db.execute('''
      CREATE TABLE $tableRawNotificationEvents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        package_name TEXT NOT NULL,
        notification_key TEXT,
        notification_id INTEGER,
        notification_tag TEXT,
        title TEXT,
        content TEXT,
        posted_at TEXT NOT NULL,
        ingested_at TEXT NOT NULL,
        payload_hash TEXT NOT NULL,
        parser_version INTEGER NOT NULL,
        processing_state TEXT NOT NULL,
        structural_fingerprint TEXT,
        supersedes_event_id INTEGER,
        exact_duplicate_of_event_id INTEGER,
        duplicate_rationale TEXT,
        FOREIGN KEY (supersedes_event_id)
          REFERENCES $tableRawNotificationEvents (id) ON DELETE SET NULL,
        FOREIGN KEY (exact_duplicate_of_event_id)
          REFERENCES $tableRawNotificationEvents (id) ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableParsedFinancialEvents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        raw_notification_event_id INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        status TEXT NOT NULL,
        direction TEXT NOT NULL,
        amount_minor INTEGER,
        currency_code TEXT,
        merchant_raw TEXT,
        merchant_normalized TEXT,
        institution_id TEXT,
        instrument_last_four TEXT,
        reference_number TEXT,
        payment_rail TEXT,
        transaction_occurred_at TEXT,
        overall_confidence REAL NOT NULL,
        field_confidence TEXT NOT NULL,
        parse_decision TEXT NOT NULL,
        failure_code TEXT,
        ledger_duplicate_confidence REAL NOT NULL DEFAULT 0,
        ledger_duplicate_rationale TEXT,
        FOREIGN KEY (raw_notification_event_id)
          REFERENCES $tableRawNotificationEvents (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableTransactionGroups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_type TEXT NOT NULL,
        merchant_normalized TEXT,
        category TEXT,
        original_amount_minor INTEGER,
        refundable_amount_minor INTEGER,
        completed_refund_amount_minor INTEGER NOT NULL DEFAULT 0,
        net_expense_minor INTEGER NOT NULL,
        transfer_type TEXT,
        is_inconsistent INTEGER NOT NULL DEFAULT 0,
        inconsistency_reason TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableLedgerEntries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_group_id INTEGER,
        parsed_financial_event_id INTEGER,
        legacy_transaction_id INTEGER,
        account_id INTEGER NOT NULL,
        direction TEXT NOT NULL,
        amount_minor INTEGER NOT NULL CHECK(amount_minor >= 0),
        currency_code TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        event_role TEXT NOT NULL,
        category TEXT,
        merchant TEXT,
        is_provisional INTEGER NOT NULL DEFAULT 0 CHECK(is_provisional IN (0, 1)),
        created_at TEXT NOT NULL,
        FOREIGN KEY (transaction_group_id)
          REFERENCES $tableTransactionGroups (id) ON DELETE SET NULL,
        FOREIGN KEY (parsed_financial_event_id)
          REFERENCES $tableParsedFinancialEvents (id) ON DELETE SET NULL,
        FOREIGN KEY (legacy_transaction_id)
          REFERENCES $tableTransactions (id) ON DELETE CASCADE,
        FOREIGN KEY (account_id)
          REFERENCES $tableAccounts (id) ON DELETE CASCADE
      )
    ''');
    await _createEventLinkTables(db);

    await db.execute(
      'CREATE INDEX idx_raw_notification_payload_hash '
      'ON $tableRawNotificationEvents (payload_hash)',
    );
    await db.execute(
      'CREATE INDEX idx_raw_notification_package_posted '
      'ON $tableRawNotificationEvents (package_name, posted_at)',
    );
    await db.execute(
      'CREATE INDEX idx_parsed_reference_number '
      'ON $tableParsedFinancialEvents (reference_number)',
    );
    await db.execute(
      'CREATE INDEX idx_parsed_instrument_last_four '
      'ON $tableParsedFinancialEvents (instrument_last_four)',
    );
    await db.execute(
      'CREATE INDEX idx_accounts_last_four ON $tableAccounts (last_four)',
    );
    await db.execute(
      'CREATE INDEX idx_ledger_account_occurred '
      'ON $tableLedgerEntries (account_id, occurred_at)',
    );
    await db.execute(
      'CREATE INDEX idx_ledger_transaction_group '
      'ON $tableLedgerEntries (transaction_group_id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_ledger_legacy_transaction '
      'ON $tableLedgerEntries (legacy_transaction_id) '
      'WHERE legacy_transaction_id IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX idx_raw_supersedes '
      'ON $tableRawNotificationEvents (supersedes_event_id)',
    );
    await db.execute(
      'CREATE INDEX idx_raw_exact_duplicate '
      'ON $tableRawNotificationEvents (exact_duplicate_of_event_id)',
    );
  }

  Future<void> _createEventLinkTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableParsedEventLedgerLinks (
        parsed_financial_event_id INTEGER NOT NULL,
        ledger_entry_id INTEGER NOT NULL,
        match_rationale TEXT NOT NULL,
        confidence REAL NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (parsed_financial_event_id, ledger_entry_id),
        FOREIGN KEY (parsed_financial_event_id)
          REFERENCES $tableParsedFinancialEvents (id) ON DELETE CASCADE,
        FOREIGN KEY (ledger_entry_id)
          REFERENCES $tableLedgerEntries (id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableParsedEventGroupLinks (
        parsed_financial_event_id INTEGER NOT NULL,
        transaction_group_id INTEGER NOT NULL,
        match_rationale TEXT NOT NULL,
        confidence REAL NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (parsed_financial_event_id, transaction_group_id),
        FOREIGN KEY (parsed_financial_event_id)
          REFERENCES $tableParsedFinancialEvents (id) ON DELETE CASCADE,
        FOREIGN KEY (transaction_group_id)
          REFERENCES $tableTransactionGroups (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_event_ledger_link '
      'ON $tableParsedEventLedgerLinks (ledger_entry_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_event_group_link '
      'ON $tableParsedEventGroupLinks (transaction_group_id)',
    );
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
    final rows = await db.query(tableAccounts, orderBy: 'display_name ASC');

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
    return db.delete(tableAccounts, where: 'id = ?', whereArgs: [id]);
  }

  /// Atomically folds a provisional instrument into a confirmed account.
  ///
  /// Both legacy transactions and ledger entries move to the confirmed
  /// account. Opening balances are combined once, then the confirmed balance
  /// is rebuilt from that baseline and the moved ledger.
  Future<void> mergeProvisionalAccount({
    required int provisionalAccountId,
    required int confirmedAccountId,
  }) async {
    if (provisionalAccountId == confirmedAccountId) {
      throw ArgumentError('An account cannot be merged into itself.');
    }
    final db = await database;
    await db.transaction((txn) async {
      final provisionalRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [provisionalAccountId],
        limit: 1,
      );
      final confirmedRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [confirmedAccountId],
        limit: 1,
      );
      if (provisionalRows.isEmpty || confirmedRows.isEmpty) {
        throw StateError('Both merge accounts must exist.');
      }
      final provisional = Account.fromMap(provisionalRows.single);
      final confirmed = Account.fromMap(confirmedRows.single);
      if (!provisional.isProvisional) {
        throw StateError('Source account is not provisional.');
      }

      await txn.insert(tableAccountMerges, {
        'provisional_account_id': provisionalAccountId,
        'confirmed_account_id': confirmedAccountId,
        'provisional_display_name': provisional.displayName,
        'provisional_opening_balance_minor': provisional.openingBalanceMinor,
        'merged_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.update(
        tableTransactions,
        {'account_id': confirmedAccountId},
        where: 'account_id = ?',
        whereArgs: [provisionalAccountId],
      );
      await txn.update(
        tableLedgerEntries,
        {'account_id': confirmedAccountId},
        where: 'account_id = ?',
        whereArgs: [provisionalAccountId],
      );
      await txn.update(
        tableAccounts,
        {
          'opening_balance_minor':
              confirmed.openingBalanceMinor + provisional.openingBalanceMinor,
        },
        where: 'id = ?',
        whereArgs: [confirmedAccountId],
      );
      await txn.delete(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [provisionalAccountId],
      );
      await _rebuildAccountBalance(txn, confirmedAccountId);
    });
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
        final currentBalance = (accountRows.first['current_balance'] as num)
            .toDouble();
        final change = transaction.type == TransactionType.credit
            ? transaction.amount
            : -transaction.amount;
        final newBalance = currentBalance + change;
        final openingBalanceMinor =
            accountRows.first['opening_balance_minor'] as int;
        await txn.update(
          tableAccounts,
          {
            'current_balance': newBalance,
            'opening_balance_minor': openingBalanceMinor + majorToMinor(change),
          },
          where: 'id = ?',
          whereArgs: [transaction.accountId],
        );
      }

      return id;
    });
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
    final rows = await db.query(tableTransactions, orderBy: 'timestamp DESC');

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
      final linkedLedgerRows = await txn.query(
        tableLedgerEntries,
        columns: ['id', 'account_id'],
        where: 'legacy_transaction_id = ?',
        whereArgs: [transaction.id],
        limit: 1,
      );
      if (linkedLedgerRows.isNotEmpty) {
        final oldAccountId = linkedLedgerRows.first['account_id'] as int;
        final updated = await txn.update(
          tableTransactions,
          transaction.toMap(),
          where: 'id = ?',
          whereArgs: [transaction.id],
        );
        await txn.update(
          tableLedgerEntries,
          {
            'account_id': transaction.accountId,
            'direction': transaction.type == TransactionType.credit
                ? FinancialDirection.credit.storageValue
                : FinancialDirection.debit.storageValue,
            'amount_minor': majorToMinor(transaction.amount),
            'occurred_at': transaction.timestamp.toIso8601String(),
            'category': transaction.category,
            'merchant': transaction.merchant,
          },
          where: 'legacy_transaction_id = ?',
          whereArgs: [transaction.id],
        );
        await _rebuildAccountBalance(txn, oldAccountId);
        if (transaction.accountId != oldAccountId) {
          await _rebuildAccountBalance(txn, transaction.accountId);
        }
        return updated;
      }

      // 2. Revert old transaction balance from old account
      final oldAccRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [oldTxn.accountId],
        limit: 1,
      );
      if (oldAccRows.isNotEmpty) {
        final currentBalance = (oldAccRows.first['current_balance'] as num)
            .toDouble();
        final revertChange = oldTxn.type == TransactionType.credit
            ? -oldTxn.amount
            : oldTxn.amount;
        final openingBalanceMinor =
            oldAccRows.first['opening_balance_minor'] as int;
        await txn.update(
          tableAccounts,
          {
            'current_balance': currentBalance + revertChange,
            'opening_balance_minor':
                openingBalanceMinor + majorToMinor(revertChange),
          },
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
          currentBalance = (updatedAccRows.first['current_balance'] as num)
              .toDouble();
        } else {
          currentBalance = (newAccRows.first['current_balance'] as num)
              .toDouble();
        }

        final applyChange = transaction.type == TransactionType.credit
            ? transaction.amount
            : -transaction.amount;
        final openingBalanceMinor = transaction.accountId == oldTxn.accountId
            ? (await txn.query(
                    tableAccounts,
                    columns: ['opening_balance_minor'],
                    where: 'id = ?',
                    whereArgs: [transaction.accountId],
                    limit: 1,
                  )).first['opening_balance_minor']
                  as int
            : newAccRows.first['opening_balance_minor'] as int;
        await txn.update(
          tableAccounts,
          {
            'current_balance': currentBalance + applyChange,
            'opening_balance_minor':
                openingBalanceMinor + majorToMinor(applyChange),
          },
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
      final linkedLedgerRows = await txn.query(
        tableLedgerEntries,
        columns: ['account_id'],
        where: 'legacy_transaction_id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (linkedLedgerRows.isNotEmpty) {
        final accountId = linkedLedgerRows.first['account_id'] as int;
        final deleted = await txn.delete(
          tableTransactions,
          where: 'id = ?',
          whereArgs: [id],
        );
        await _rebuildAccountBalance(txn, accountId);
        return deleted;
      }

      // 2. Revert old transaction balance from account
      final accRows = await txn.query(
        tableAccounts,
        where: 'id = ?',
        whereArgs: [oldTxn.accountId],
        limit: 1,
      );
      if (accRows.isNotEmpty) {
        final currentBalance = (accRows.first['current_balance'] as num)
            .toDouble();
        final revertChange = oldTxn.type == TransactionType.credit
            ? -oldTxn.amount
            : oldTxn.amount;
        final openingBalanceMinor =
            accRows.first['opening_balance_minor'] as int;
        await txn.update(
          tableAccounts,
          {
            'current_balance': currentBalance + revertChange,
            'opening_balance_minor':
                openingBalanceMinor + majorToMinor(revertChange),
          },
          where: 'id = ?',
          whereArgs: [oldTxn.accountId],
        );
      }

      // 3. Delete the transaction
      return txn.delete(tableTransactions, where: 'id = ?', whereArgs: [id]);
    });
  }

  // --- Notification and financial lifecycle domain ---

  Future<int> createRawNotificationEvent(RawNotificationEvent event) async {
    final db = await database;
    return db.insert(tableRawNotificationEvents, event.toMap());
  }

  Future<RawNotificationInsertResult> insertRawNotificationIdempotently(
    RawNotificationEvent event,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final payloadMatches = await txn.query(
        tableRawNotificationEvents,
        where: 'package_name = ? AND payload_hash = ?',
        whereArgs: [event.packageName, event.payloadHash],
        orderBy: 'ingested_at DESC, id DESC',
        limit: 1,
      );
      final exactDuplicateOfEventId = payloadMatches.isEmpty
          ? null
          : payloadMatches.first['id'] as int;
      final priorPayload = payloadMatches.isEmpty
          ? null
          : RawNotificationEvent.fromMap(payloadMatches.first);
      final sharesNotificationIdentity =
          priorPayload != null &&
          ((event.notificationKey != null &&
                  event.notificationKey == priorPayload.notificationKey) ||
              (event.notificationId != null &&
                  event.notificationId == priorPayload.notificationId &&
                  event.notificationTag == priorPayload.notificationTag));

      int? supersedesEventId;
      if (event.notificationKey != null || event.notificationId != null) {
        final identityClauses = <String>[];
        final identityArgs = <Object?>[event.packageName];
        if (event.notificationKey != null) {
          identityClauses.add('notification_key = ?');
          identityArgs.add(event.notificationKey);
        }
        if (event.notificationId != null) {
          if (event.notificationTag == null) {
            identityClauses.add(
              '(notification_id = ? AND notification_tag IS NULL)',
            );
            identityArgs.add(event.notificationId);
          } else {
            identityClauses.add(
              '(notification_id = ? AND notification_tag = ?)',
            );
            identityArgs
              ..add(event.notificationId)
              ..add(event.notificationTag);
          }
        }
        final priorRows = await txn.query(
          tableRawNotificationEvents,
          columns: ['id'],
          where: 'package_name = ? AND (${identityClauses.join(' OR ')})',
          whereArgs: identityArgs,
          orderBy: 'ingested_at DESC, id DESC',
          limit: 1,
        );
        supersedesEventId = priorRows.isEmpty
            ? null
            : priorRows.first['id'] as int;
      }

      final eventToInsert = RawNotificationEvent(
        packageName: event.packageName,
        notificationKey: event.notificationKey,
        notificationId: event.notificationId,
        notificationTag: event.notificationTag,
        title: event.title,
        content: event.content,
        postedAt: event.postedAt,
        ingestedAt: event.ingestedAt,
        payloadHash: event.payloadHash,
        parserVersion: event.parserVersion,
        processingState: event.processingState,
        structuralFingerprint: event.structuralFingerprint,
        supersedesEventId: supersedesEventId,
        exactDuplicateOfEventId: exactDuplicateOfEventId,
        duplicateRationale: exactDuplicateOfEventId == null
            ? null
            : [
                if (sharesNotificationIdentity)
                  MatchRationale.notificationIdentity.storageValue,
                MatchRationale.payloadHash.storageValue,
              ].join(','),
      );
      final id = await txn.insert(
        tableRawNotificationEvents,
        eventToInsert.toMap(),
      );
      return RawNotificationInsertResult(
        event: RawNotificationEvent.fromMap({
          ...eventToInsert.toMap(),
          'id': id,
        }),
        wasInserted: true,
      );
    });
  }

  Future<void> updateRawNotificationProcessingState(
    int id,
    RawNotificationProcessingState state,
  ) async {
    final db = await database;
    await db.update(
      tableRawNotificationEvents,
      {'processing_state': state.storageValue},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<RawNotificationEvent>> getAllRawNotificationEvents() async {
    final db = await database;
    final rows = await db.query(tableRawNotificationEvents, orderBy: 'id ASC');
    return rows.map(RawNotificationEvent.fromMap).toList();
  }

  Future<RawNotificationEvent?> getRawNotificationEvent(int id) async {
    final db = await database;
    final rows = await db.query(
      tableRawNotificationEvents,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : RawNotificationEvent.fromMap(rows.first);
  }

  Future<int> createParsedFinancialEvent(ParsedFinancialEvent event) async {
    final db = await database;
    return db.insert(tableParsedFinancialEvents, event.toMap());
  }

  Future<int> postIngestedTransaction({
    required Transaction transaction,
    required int parsedFinancialEventId,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final transactionId = await txn.insert(
        tableTransactions,
        transaction.toMap(),
      );
      await txn.insert(
        tableLedgerEntries,
        LedgerEntry(
          parsedFinancialEventId: parsedFinancialEventId,
          legacyTransactionId: transactionId,
          accountId: transaction.accountId,
          direction: transaction.type == TransactionType.credit
              ? FinancialDirection.credit
              : FinancialDirection.debit,
          amountMinor: majorToMinor(transaction.amount),
          currencyCode: 'INR',
          occurredAt: transaction.timestamp,
          eventRole: LedgerEventRole.primary,
          category: transaction.category,
          merchant: transaction.merchant,
          createdAt: DateTime.now().toUtc(),
        ).toMap(),
      );
      final ledgerRows = await txn.query(
        tableLedgerEntries,
        columns: ['id'],
        where: 'legacy_transaction_id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );
      await txn.insert(tableParsedEventLedgerLinks, {
        'parsed_financial_event_id': parsedFinancialEventId,
        'ledger_entry_id': ledgerRows.single['id'],
        'match_rationale': 'createdLedgerEntry',
        'confidence': 1.0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _rebuildAccountBalance(txn, transaction.accountId);
      return transactionId;
    });
  }

  Future<List<LedgerMatchCandidate>> getLedgerMatchCandidates({
    required int accountId,
    required DateTime occurredAt,
    Duration searchWindow = const Duration(days: 7),
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT
        l.id AS ledger_id,
        l.amount_minor,
        l.currency_code,
        l.direction,
        l.account_id,
        l.merchant,
        l.occurred_at,
        p.reference_number,
        p.payment_rail,
        r.package_name
      FROM $tableLedgerEntries l
      LEFT JOIN $tableParsedEventLedgerLinks pel
        ON pel.ledger_entry_id = l.id
      LEFT JOIN $tableParsedFinancialEvents p
        ON p.id = COALESCE(pel.parsed_financial_event_id,
                          l.parsed_financial_event_id)
      LEFT JOIN $tableRawNotificationEvents r
        ON r.id = p.raw_notification_event_id
      WHERE l.account_id = ?
        AND l.occurred_at BETWEEN ? AND ?
      ORDER BY l.occurred_at DESC, l.id DESC
      ''',
      [
        accountId,
        occurredAt.subtract(searchWindow).toIso8601String(),
        occurredAt.add(searchWindow).toIso8601String(),
      ],
    );
    final seen = <int>{};
    return rows.where((row) => seen.add(row['ledger_id'] as int)).map((row) {
      return LedgerMatchCandidate(
        ledgerEntryId: row['ledger_id'] as int,
        fingerprint: FinancialEventFingerprint(
          amountMinor: row['amount_minor'] as int,
          currencyCode: row['currency_code'] as String,
          direction: row['direction'] as String,
          accountId: row['account_id'] as int,
          merchant: row['merchant'] as String?,
          reference: row['reference_number'] as String?,
          paymentRail: row['payment_rail'] as String?,
          occurredAt: DateTime.parse(row['occurred_at'] as String),
          sourcePackage: row['package_name'] as String? ?? '',
        ),
      );
    }).toList();
  }

  Future<void> linkParsedEventToLedger({
    required int parsedFinancialEventId,
    required int ledgerEntryId,
    required DuplicateAssessment assessment,
  }) async {
    final db = await database;
    await db.insert(tableParsedEventLedgerLinks, {
      'parsed_financial_event_id': parsedFinancialEventId,
      'ledger_entry_id': ledgerEntryId,
      'match_rationale': assessment.rationales
          .map((rationale) => rationale.storageValue)
          .join(','),
      'confidence': assessment.confidence,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> getParsedEventLedgerLinks() async {
    final db = await database;
    return db.query(
      tableParsedEventLedgerLinks,
      orderBy: 'parsed_financial_event_id ASC',
    );
  }

  Future<int?> getLedgerEntryIdForRawEvent(int rawEventId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(pel.ledger_entry_id, l.id) AS ledger_id
      FROM $tableParsedFinancialEvents p
      LEFT JOIN $tableParsedEventLedgerLinks pel
        ON pel.parsed_financial_event_id = p.id
      LEFT JOIN $tableLedgerEntries l
        ON l.parsed_financial_event_id = p.id
      WHERE p.raw_notification_event_id = ?
        AND COALESCE(pel.ledger_entry_id, l.id) IS NOT NULL
      ORDER BY p.id DESC
      LIMIT 1
      ''',
      [rawEventId],
    );
    return rows.isEmpty ? null : rows.single['ledger_id'] as int;
  }

  Future<void> updateLedgerCategoryForParsedEvent(
    int parsedFinancialEventId,
    String? category,
  ) async {
    final db = await database;
    await db.rawUpdate(
      '''
      UPDATE $tableLedgerEntries
      SET category = ?
      WHERE id IN (
        SELECT ledger_entry_id
        FROM $tableParsedEventLedgerLinks
        WHERE parsed_financial_event_id = ?
      )
      ''',
      [category, parsedFinancialEventId],
    );
    final parsedRows = await db.query(
      tableParsedFinancialEvents,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [parsedFinancialEventId],
      limit: 1,
    );
    if (parsedRows.isNotEmpty) {
      await db.rawUpdate(
        '''
        UPDATE $tableTransactions
        SET category = ?
        WHERE id IN (
          SELECT legacy_transaction_id
          FROM $tableLedgerEntries
          WHERE parsed_financial_event_id = ?
             OR id IN (
               SELECT ledger_entry_id
               FROM $tableParsedEventLedgerLinks
               WHERE parsed_financial_event_id = ?
             )
        )
        ''',
        [
          category ?? 'Uncategorized',
          parsedFinancialEventId,
          parsedFinancialEventId,
        ],
      );
    }
  }

  Future<void> linkParsedEventToGroup({
    required int parsedFinancialEventId,
    required int transactionGroupId,
    required DuplicateAssessment assessment,
  }) async {
    final db = await database;
    await db.insert(tableParsedEventGroupLinks, {
      'parsed_financial_event_id': parsedFinancialEventId,
      'transaction_group_id': transactionGroupId,
      'match_rationale': assessment.rationales
          .map((rationale) => rationale.storageValue)
          .join(','),
      'confidence': assessment.confidence,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> getParsedEventGroupLinks() async {
    final db = await database;
    return db.query(
      tableParsedEventGroupLinks,
      orderBy: 'parsed_financial_event_id ASC',
    );
  }

  Future<List<Map<String, Object?>>> getRelatedGroupCandidates({
    int? accountId,
  }) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT
        peg.transaction_group_id,
        p.event_type,
        p.direction,
        p.amount_minor,
        l.account_id,
        p.merchant_normalized,
        p.reference_number,
        p.transaction_occurred_at,
        r.package_name
      FROM $tableParsedEventGroupLinks peg
      JOIN $tableParsedFinancialEvents p
        ON p.id = peg.parsed_financial_event_id
      JOIN $tableRawNotificationEvents r
        ON r.id = p.raw_notification_event_id
      JOIN $tableParsedEventLedgerLinks pel
        ON pel.parsed_financial_event_id = p.id
      JOIN $tableLedgerEntries l
        ON l.id = pel.ledger_entry_id
      ${accountId == null ? '' : 'WHERE l.account_id = ?'}
      ORDER BY p.transaction_occurred_at DESC, p.id DESC
      ''',
      [?accountId],
    );
  }

  Future<void> updateTransactionGroupType(
    int transactionGroupId,
    TransactionGroupType groupType,
  ) async {
    final db = await database;
    await db.update(
      tableTransactionGroups,
      {
        'group_type': groupType.storageValue,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [transactionGroupId],
    );
  }

  Future<ParsedFinancialEvent?> getParsedFinancialEvent(int id) async {
    final db = await database;
    final rows = await db.query(
      tableParsedFinancialEvents,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : ParsedFinancialEvent.fromMap(rows.first);
  }

  Future<int> createTransactionGroup(TransactionGroup group) async {
    final db = await database;
    return db.insert(tableTransactionGroups, group.toMap());
  }

  Future<TransactionGroup?> getTransactionGroup(int id) async {
    final db = await database;
    final rows = await db.query(
      tableTransactionGroups,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : TransactionGroup.fromMap(rows.first);
  }

  Future<void> updateTransactionGroupLifecycle({
    required int transactionGroupId,
    required TransactionGroupType groupType,
    required int completedRefundAmountMinor,
    required int netExpenseMinor,
    required bool isInconsistent,
    String? inconsistencyReason,
  }) async {
    final db = await database;
    await db.update(
      tableTransactionGroups,
      {
        'group_type': groupType.storageValue,
        'completed_refund_amount_minor': completedRefundAmountMinor,
        'net_expense_minor': netExpenseMinor,
        'is_inconsistent': isInconsistent ? 1 : 0,
        'inconsistency_reason': inconsistencyReason,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [transactionGroupId],
    );
  }

  Future<int> createLedgerEntry(LedgerEntry entry) async {
    if (entry.amountMinor < 0) {
      throw ArgumentError.value(
        entry.amountMinor,
        'amountMinor',
        'Ledger amounts must be non-negative.',
      );
    }
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert(tableLedgerEntries, entry.toMap());
      await _rebuildAccountBalance(txn, entry.accountId);
      return id;
    });
  }

  Future<LedgerEntry?> getLedgerEntry(int id) async {
    final db = await database;
    final rows = await db.query(
      tableLedgerEntries,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : LedgerEntry.fromMap(rows.first);
  }

  Future<List<LedgerEntry>> getLedgerEntriesByGroup(
    int transactionGroupId,
  ) async {
    final db = await database;
    final rows = await db.query(
      tableLedgerEntries,
      where: 'transaction_group_id = ?',
      whereArgs: [transactionGroupId],
      orderBy: 'occurred_at ASC, id ASC',
    );
    return rows.map(LedgerEntry.fromMap).toList();
  }

  Future<int> rebuildAccountBalance(int accountId) async {
    final db = await database;
    return db.transaction((txn) => _rebuildAccountBalance(txn, accountId));
  }

  Future<int> _rebuildAccountBalance(
    DatabaseExecutor executor,
    int accountId,
  ) async {
    final accountRows = await executor.query(
      tableAccounts,
      columns: ['opening_balance_minor'],
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (accountRows.isEmpty) {
      throw StateError('Account with id $accountId not found.');
    }

    final totals = await executor.rawQuery(
      '''
      SELECT COALESCE(SUM(
        CASE
          WHEN direction = 'credit' THEN amount_minor
          WHEN direction = 'debit' THEN -amount_minor
          ELSE 0
        END
      ), 0) AS ledger_total
      FROM $tableLedgerEntries
      WHERE account_id = ? AND is_provisional = 0
      ''',
      [accountId],
    );
    final openingBalanceMinor =
        accountRows.first['opening_balance_minor'] as int;
    final ledgerTotal = (totals.first['ledger_total'] as num).toInt();
    final rebuiltMinor = openingBalanceMinor + ledgerTotal;
    await executor.update(
      tableAccounts,
      {'current_balance': minorToMajor(rebuiltMinor)},
      where: 'id = ?',
      whereArgs: [accountId],
    );
    return rebuiltMinor;
  }

  Future<double> getTotalBalance() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT SUM(current_balance) as total FROM $tableAccounts',
    );
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
    final currentMonthStr = DateTime.now().toIso8601String().substring(
      0,
      7,
    ); // YYYY-MM

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
