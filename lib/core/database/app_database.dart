import 'dart:async';
import 'dart:io';

import 'package:expense_tracker/core/database/database_migrator.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_presentations.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/notification_template.dart';
import 'package:expense_tracker/core/models/parser_diagnostic.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/review_transaction.dart';
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
  static const databaseVersion = 11;

  static const tableAccounts = 'accounts';
  static const tableTransactions = 'transactions';
  static const tableRawNotificationEvents = 'raw_notification_events';
  static const tableParsedFinancialEvents = 'parsed_financial_events';
  static const tableTransactionGroups = 'transaction_groups';
  static const tableLedgerEntries = 'ledger_entries';
  static const tableAccountMerges = 'account_merges';
  static const tableParsedEventLedgerLinks = 'parsed_event_ledger_links';
  static const tableParsedEventGroupLinks = 'parsed_event_group_links';
  static const tableNotificationTemplates = 'notification_templates';
  static const tableParserDiagnostics = 'parser_diagnostics';

  Database? _database;
  Future<Database>? _databaseFuture;
  String? _passphrase;
  int _generation = 0;

  Future<Database> get database async {
    while (true) {
      final existing = _database;
      if (existing != null && existing.isOpen) {
        return existing;
      }

      try {
        final generation = _generation;
        _databaseFuture ??= _initDatabase();
        _database = await _databaseFuture;
        if (generation != _generation) {
          final superseded = _database;
          _database = null;
          _databaseFuture = null;
          if (superseded?.isOpen ?? false) await superseded!.close();
          continue;
        }
        return _database!;
      } catch (e) {
        _databaseFuture = null;
        _database = null;
        rethrow;
      }
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
    await DatabaseMigrator.instance.prepare(path, _passphrase!);

    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await openDatabase(
          path,
          password: _passphrase,
          version: databaseVersion,
          singleInstance: true,
          onConfigure: _configureConnection,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
          onOpen: _validateOpenedDatabase,
        );
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 150 * (attempt + 1)),
          );
        }
      }
    }
    throw StateError(
      'Encrypted database could not be opened after retry: '
      '${lastError.runtimeType}',
    );
  }

  Future<void> _configureConnection(Database db) async {
    await db.rawQuery('PRAGMA foreign_keys = ON');
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA secure_delete = ON');
    await db.rawQuery('PRAGMA synchronous = FULL');
    await db.rawQuery('PRAGMA journal_mode = WAL');
  }

  Future<void> _validateOpenedDatabase(Database db) async {
    await db.rawQuery('SELECT count(*) FROM sqlite_master');
    final foreignKeys = await db.rawQuery('PRAGMA foreign_keys');
    if (foreignKeys.isEmpty || foreignKeys.first.values.first != 1) {
      throw StateError('Foreign-key enforcement is not enabled.');
    }
    final check = await db.rawQuery('PRAGMA quick_check(1)');
    if (check.isEmpty ||
        check.first.values.first.toString().toLowerCase() != 'ok') {
      throw StateError('Database integrity validation failed.');
    }
    final cipherCheck = await db.rawQuery('PRAGMA cipher_integrity_check');
    if (cipherCheck.isNotEmpty) {
      throw StateError('Encrypted page integrity validation failed.');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createVersion2Schema(db);
    await _createAccountMergesTable(db);
    await _createNotificationTemplatesTable(db);
    await _createParserDiagnosticsTable(db);
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
        case 6:
          await _upgradeFrom6To7(db);
        case 7:
          await _createNotificationTemplatesTable(db);
        case 8:
          await _upgradeFrom8To9(db);
        case 9:
          await _upgradeFrom9To10(db);
        case 10:
          await _createParserDiagnosticsTable(db);
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

  Future<void> _upgradeFrom6To7(Database db) async {
    if (!await _tableExists(db, tableAccounts)) return;
    final rows = await db.query(
      tableAccounts,
      columns: ['id', 'display_name', 'last_four'],
    );
    for (final row in rows) {
      final currentName = row['display_name'] as String;
      final suffix =
          row['last_four'] as String? ??
          Account.extractSafeTrailingFour(currentName);
      final compact = Account.formatDisplayName(currentName, suffix);
      await db.update(
        tableAccounts,
        {'display_name': compact, 'last_four': ?suffix},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
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

  Future<void> _createNotificationTemplatesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableNotificationTemplates (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fingerprint TEXT NOT NULL CHECK(length(trim(fingerprint)) > 0),
        source_package TEXT NOT NULL CHECK(length(trim(source_package)) > 0),
        observed_count INTEGER NOT NULL CHECK(observed_count >= 1),
        successful_parse_count INTEGER NOT NULL
          CHECK(successful_parse_count >= 0 AND successful_parse_count <= observed_count),
        conflicting_parse_count INTEGER NOT NULL
          CHECK(conflicting_parse_count >= 0 AND conflicting_parse_count <= observed_count),
        last_observed TEXT NOT NULL,
        field_position_metadata TEXT NOT NULL,
        promotion_status TEXT NOT NULL DEFAULT 'learning'
          CHECK(promotion_status IN ('learning', 'promoted', 'blocked')),
        role_signature TEXT NOT NULL CHECK(length(trim(role_signature)) > 0),
        UNIQUE(fingerprint, source_package)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notification_templates_package '
      'ON $tableNotificationTemplates (source_package, promotion_status)',
    );
  }

  Future<void> _upgradeFrom8To9(Database db) async {
    final columns = await db.rawQuery(
      'PRAGMA table_info($tableNotificationTemplates)',
    );
    if (columns.any((column) => column['name'] == 'promotion_status')) {
      return;
    }

    const legacyTable = 'notification_templates_v8';
    await db.execute('DROP INDEX IF EXISTS idx_notification_templates_package');
    await db.execute(
      'ALTER TABLE $tableNotificationTemplates RENAME TO $legacyTable',
    );
    await _createNotificationTemplatesTable(db);
    await db.execute('''
      INSERT INTO $tableNotificationTemplates (
        id,
        fingerprint,
        source_package,
        observed_count,
        successful_parse_count,
        conflicting_parse_count,
        last_observed,
        field_position_metadata,
        promotion_status,
        role_signature
      )
      SELECT
        id,
        fingerprint,
        trim(source_package),
        observed_count,
        successful_parse_count,
        conflicting_parse_count,
        last_observed,
        field_position_metadata,
        CASE
          WHEN conflicting_parse_count > 0 THEN 'blocked'
          WHEN is_promoted = 1 THEN 'promoted'
          ELSE 'learning'
        END,
        role_signature
      FROM $legacyTable
    ''');
    await db.execute('DROP TABLE $legacyTable');
  }

  Future<void> _upgradeFrom9To10(Database db) async {
    if (!await _tableExists(db, tableParsedFinancialEvents)) return;
    await _addColumnIfMissing(
      db,
      tableParsedFinancialEvents,
      'classification_metadata',
      "TEXT NOT NULL DEFAULT '{}'",
    );
  }

  Future<void> _createParserDiagnosticsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableParserDiagnostics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        observed_at TEXT NOT NULL,
        parser_version INTEGER NOT NULL CHECK(parser_version > 0),
        extractors_used TEXT NOT NULL CHECK(length(extractors_used) > 2),
        decision TEXT NOT NULL CHECK(length(trim(decision)) > 0),
        confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
        failure_code TEXT,
        source_category TEXT NOT NULL CHECK(length(trim(source_category)) > 0),
        structural_fingerprint TEXT NOT NULL
          CHECK(length(structural_fingerprint) <= 2048)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_parser_diagnostics_observed '
      'ON $tableParserDiagnostics (observed_at DESC)',
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
        classification_metadata TEXT NOT NULL DEFAULT '{}',
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
    _generation++;
    final pending = _databaseFuture;
    Database? db = _database;
    if (db == null && pending != null) {
      try {
        db = await pending;
      } catch (_) {
        // A failed open has no handle to close.
      }
    }
    if (db != null && db.isOpen) {
      await db.close();
    }
    _database = null;
    _databaseFuture = null;
    _passphrase = null;
  }

  // --- Accounts CRUD ---

  Future<int> createAccount(Account account) async {
    final db = await database;
    final suffix =
        account.lastFour ??
        Account.extractSafeTrailingFour(account.displayName);
    final normalized = account.copyWith(
      displayName: Account.formatDisplayName(account.displayName, suffix),
      lastFour: suffix,
    );
    return db.insert(tableAccounts, normalized.toMap());
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

  /// Lifecycle-aware totals for presentation. The date range is applied to
  /// posted ledger movements, so a refund in a later month reduces that
  /// month's net expense without rewriting the purchase month.
  Future<FinancialSummary> getFinancialSummary({
    DateTime? start,
    DateTime? end,
  }) async {
    final db = await database;
    final clauses = <String>[];
    final args = <Object?>[];
    if (start != null) {
      clauses.add('l.occurred_at >= ?');
      args.add(start.toIso8601String());
    }
    if (end != null) {
      clauses.add('l.occurred_at < ?');
      args.add(end.toIso8601String());
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN l.direction = 'debit'
          AND l.event_role = 'primary'
          AND (g.group_type IS NULL OR g.group_type NOT IN ('transfer','reversal'))
          THEN l.amount_minor ELSE 0 END), 0) gross_expenses,
        COALESCE(SUM(CASE WHEN l.event_role = 'refund'
          AND l.direction = 'credit' THEN l.amount_minor ELSE 0 END), 0) refunds,
        COALESCE(SUM(CASE WHEN l.direction = 'credit'
          AND l.event_role = 'primary'
          AND (g.group_type IS NULL OR g.group_type NOT IN
            ('transfer','cashbackRelated','reversal','purchaseRefund','partialRefund'))
          THEN l.amount_minor ELSE 0 END), 0) income,
        COALESCE(SUM(CASE WHEN g.group_type = 'cashbackRelated'
          AND l.direction = 'credit' THEN l.amount_minor ELSE 0 END), 0) cashback,
        COALESCE(SUM(CASE WHEN l.event_role = 'fee'
          AND l.direction = 'debit' THEN l.amount_minor ELSE 0 END), 0) fees,
        COALESCE(SUM(CASE WHEN g.group_type = 'transfer'
          AND l.direction = 'debit' THEN l.amount_minor ELSE 0 END), 0) transfers
      FROM $tableLedgerEntries l
      LEFT JOIN $tableTransactionGroups g ON g.id = l.transaction_group_id
      $where
    ''', args);
    final row = rows.single;

    // Manual transactions created by older/current UI have no ledger row.
    final manualClauses = <String>[
      'NOT EXISTS (SELECT 1 FROM $tableLedgerEntries l2 '
          'WHERE l2.legacy_transaction_id = t.id)',
    ];
    final manualArgs = <Object?>[];
    if (start != null) {
      manualClauses.add('t.timestamp >= ?');
      manualArgs.add(start.toIso8601String());
    }
    if (end != null) {
      manualClauses.add('t.timestamp < ?');
      manualArgs.add(end.toIso8601String());
    }
    final manual = (await db.rawQuery('''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'debit' THEN CAST(ROUND(amount * 100) AS INTEGER) ELSE 0 END), 0) expenses,
        COALESCE(SUM(CASE WHEN type = 'credit' THEN CAST(ROUND(amount * 100) AS INTEGER) ELSE 0 END), 0) income
      FROM $tableTransactions t
      WHERE ${manualClauses.join(' AND ')}
    ''', manualArgs)).single;
    final balances = (await db.rawQuery(
      'SELECT COALESCE(SUM(CAST(ROUND(current_balance * 100) AS INTEGER)), 0) total FROM $tableAccounts',
    )).single;
    final gross = (row['gross_expenses'] as int) + (manual['expenses'] as int);
    final refunds = row['refunds'] as int;
    return FinancialSummary(
      grossExpensesMinor: gross,
      completedRefundsMinor: refunds,
      netExpensesMinor: gross - refunds,
      incomeMinor: (row['income'] as int) + (manual['income'] as int),
      cashbackMinor: row['cashback'] as int,
      feesMinor: row['fees'] as int,
      transfersMinor: row['transfers'] as int,
      accountBalancesMinor: balances['total'] as int,
    );
  }

  Future<List<CategoryFinancialSummary>> getCategoryFinancialSummaries({
    DateTime? start,
    DateTime? end,
  }) async {
    final db = await database;
    final clauses = <String>[];
    final args = <Object?>[];
    if (start != null) {
      clauses.add('l.occurred_at >= ?');
      args.add(start.toIso8601String());
    }
    if (end != null) {
      clauses.add('l.occurred_at < ?');
      args.add(end.toIso8601String());
    }
    final dateWhere = clauses.isEmpty ? '' : 'AND ${clauses.join(' AND ')}';
    final rows = await db.rawQuery('''
      SELECT COALESCE(l.category, g.category, 'Other') category,
        SUM(CASE WHEN l.direction = 'debit' AND l.event_role = 'primary'
          AND (g.group_type IS NULL OR g.group_type NOT IN ('transfer','reversal'))
          THEN l.amount_minor ELSE 0 END) gross,
        SUM(CASE WHEN l.direction = 'credit' AND l.event_role = 'refund'
          THEN l.amount_minor ELSE 0 END) refunds
      FROM $tableLedgerEntries l
      LEFT JOIN $tableTransactionGroups g ON g.id = l.transaction_group_id
      WHERE 1=1 $dateWhere
      GROUP BY COALESCE(l.category, g.category, 'Other')
    ''', args);
    final result = <String, CategoryFinancialSummary>{
      for (final row in rows)
        row['category'] as String: CategoryFinancialSummary(
          category: row['category'] as String,
          grossSpendMinor: row['gross'] as int,
          refundsMinor: row['refunds'] as int,
        ),
    };
    final manualClauses = <String>[
      "t.type = 'debit'",
      'NOT EXISTS (SELECT 1 FROM $tableLedgerEntries l2 WHERE l2.legacy_transaction_id = t.id)',
    ];
    final manualArgs = <Object?>[];
    if (start != null) {
      manualClauses.add('t.timestamp >= ?');
      manualArgs.add(start.toIso8601String());
    }
    if (end != null) {
      manualClauses.add('t.timestamp < ?');
      manualArgs.add(end.toIso8601String());
    }
    final manualRows = await db.rawQuery('''
      SELECT category, SUM(CAST(ROUND(amount * 100) AS INTEGER)) gross
      FROM $tableTransactions t WHERE ${manualClauses.join(' AND ')}
      GROUP BY category
    ''', manualArgs);
    for (final row in manualRows) {
      final category = row['category'] as String;
      final old = result[category];
      result[category] = CategoryFinancialSummary(
        category: category,
        grossSpendMinor: (old?.grossSpendMinor ?? 0) + (row['gross'] as int),
        refundsMinor: old?.refundsMinor ?? 0,
      );
    }
    final values = result.values
        .where((e) => e.grossSpendMinor != 0 || e.refundsMinor != 0)
        .toList();
    values.sort((a, b) => b.netSpendMinor.compareTo(a.netSpendMinor));
    return values;
  }

  Future<List<AccountLedgerMovement>> getAccountLedgerMovements({
    int? accountId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT l.*, a.display_name account_name, g.group_type
      FROM $tableLedgerEntries l
      JOIN $tableAccounts a ON a.id = l.account_id
      LEFT JOIN $tableTransactionGroups g ON g.id = l.transaction_group_id
      ${accountId == null ? '' : 'WHERE l.account_id = ?'}
      ORDER BY l.occurred_at DESC, l.id DESC
    ''',
      [?accountId],
    );
    return rows
        .map(
          (row) => AccountLedgerMovement(
            entry: LedgerEntry.fromMap(row),
            accountName: row['account_name'] as String,
            groupType: row['group_type'] == null
                ? null
                : TransactionGroupType.fromStorage(row['group_type'] as String),
          ),
        )
        .toList();
  }

  Future<List<TransactionStory>> getTransactionStories() async {
    final db = await database;
    final groupRows = await db.query(
      tableTransactionGroups,
      orderBy: 'updated_at DESC, id DESC',
    );
    final stories = <TransactionStory>[];
    for (final row in groupRows) {
      final group = TransactionGroup.fromMap(row);
      final movements = (await getAccountLedgerMovements())
          .where((movement) => movement.entry.transactionGroupId == group.id)
          .toList();
      final eventRows = await db.rawQuery(
        '''
        SELECT p.* FROM $tableParsedFinancialEvents p
        JOIN $tableParsedEventGroupLinks link
          ON link.parsed_financial_event_id = p.id
        WHERE link.transaction_group_id = ?
          AND NOT EXISTS (
            SELECT 1 FROM $tableParsedEventLedgerLinks ledger_link
            WHERE ledger_link.parsed_financial_event_id = p.id
          )
        ORDER BY p.transaction_occurred_at ASC, p.id ASC
      ''',
        [group.id],
      );
      stories.add(
        TransactionStory(
          group: group,
          movements: movements,
          informationalEvents: eventRows
              .map(ParsedFinancialEvent.fromMap)
              .toList(),
        ),
      );
    }
    return stories;
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

  /// Records only a value-free structural template. [fieldPositionMetadata]
  /// and [roleSignature] are application-generated data; neither is executed.
  Future<NotificationTemplate> observeNotificationTemplate({
    required String fingerprint,
    required String sourcePackage,
    required NotificationTemplateFieldMetadata fieldPositionMetadata,
    required String roleSignature,
    required bool successfulCompletedParse,
    required DateTime observedAt,
  }) async {
    final normalizedFingerprint = fingerprint.trim();
    final normalizedPackage = sourcePackage.trim();
    _validateNotificationTemplateObservation(
      fingerprint: normalizedFingerprint,
      sourcePackage: normalizedPackage,
      fieldPositionMetadata: fieldPositionMetadata,
      roleSignature: roleSignature,
    );
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        tableNotificationTemplates,
        where: 'fingerprint = ? AND source_package = ?',
        whereArgs: [normalizedFingerprint, normalizedPackage],
        limit: 1,
      );
      if (rows.isEmpty) {
        final template = NotificationTemplate(
          fingerprint: normalizedFingerprint,
          sourcePackage: normalizedPackage,
          observedCount: 1,
          successfulParseCount: successfulCompletedParse ? 1 : 0,
          conflictingParseCount: 0,
          lastObserved: observedAt,
          fieldPositionMetadata: fieldPositionMetadata,
          promotionStatus: NotificationTemplatePromotionStatus.learning,
          roleSignature: roleSignature,
        );
        final id = await txn.insert(
          tableNotificationTemplates,
          template.toMap(),
        );
        return NotificationTemplate.fromMap({...template.toMap(), 'id': id});
      }

      final existing = NotificationTemplate.fromMap(rows.single);
      final conflict =
          existing.roleSignature != roleSignature ||
          existing.fieldPositionMetadata.canonicalJson !=
              fieldPositionMetadata.canonicalJson;
      final observed = existing.observedCount + 1;
      final successful =
          existing.successfulParseCount +
          (successfulCompletedParse && !conflict ? 1 : 0);
      final conflicts = existing.conflictingParseCount + (conflict ? 1 : 0);
      final promotionStatus =
          existing.promotionStatus ==
                  NotificationTemplatePromotionStatus.blocked ||
              conflict
          ? NotificationTemplatePromotionStatus.blocked
          : observed >= NotificationTemplate.minimumObservationsForPromotion &&
                successful >=
                    NotificationTemplate.minimumObservationsForPromotion &&
                conflicts == 0
          ? NotificationTemplatePromotionStatus.promoted
          : NotificationTemplatePromotionStatus.learning;
      final updated = NotificationTemplate(
        id: existing.id,
        fingerprint: normalizedFingerprint,
        sourcePackage: normalizedPackage,
        observedCount: observed,
        successfulParseCount: successful,
        conflictingParseCount: conflicts,
        lastObserved: observedAt.isAfter(existing.lastObserved)
            ? observedAt
            : existing.lastObserved,
        // Conflicting observations never overwrite the trusted field layout.
        fieldPositionMetadata: existing.fieldPositionMetadata,
        promotionStatus: promotionStatus,
        roleSignature: existing.roleSignature,
      );
      await txn.update(
        tableNotificationTemplates,
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return updated;
    });
  }

  Future<NotificationTemplate?> getNotificationTemplate({
    required String fingerprint,
    required String sourcePackage,
  }) async {
    final db = await database;
    final rows = await db.query(
      tableNotificationTemplates,
      where: 'fingerprint = ? AND source_package = ?',
      whereArgs: [fingerprint.trim(), sourcePackage.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : NotificationTemplate.fromMap(rows.single);
  }

  static final RegExp _sourcePackagePattern = RegExp(
    r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+$',
  );
  static final RegExp _roleSignaturePattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9]*(?:\|[A-Za-z][A-Za-z0-9]*)+$',
  );
  static final RegExp _placeholderPattern = RegExp(r'<[A-Z_]+>');

  void _validateNotificationTemplateObservation({
    required String fingerprint,
    required String sourcePackage,
    required NotificationTemplateFieldMetadata fieldPositionMetadata,
    required String roleSignature,
  }) {
    if (fingerprint.isEmpty ||
        fingerprint.length > 2048 ||
        fingerprint.contains('\n') ||
        fingerprint.contains('\r')) {
      throw const FormatException('Invalid notification fingerprint.');
    }
    if (sourcePackage.length > 255 ||
        !_sourcePackagePattern.hasMatch(sourcePackage)) {
      throw const FormatException('Invalid notification source package.');
    }
    if (roleSignature.length > 512 ||
        !_roleSignaturePattern.hasMatch(roleSignature)) {
      throw const FormatException('Invalid notification role signature.');
    }
    if (fieldPositionMetadata.fields.isEmpty) {
      throw const FormatException(
        'A learned notification template must contain a typed field.',
      );
    }

    final tokens = fingerprint.split(RegExp(r'\s+'));
    final knownPlaceholders = NotificationTemplateFieldType.values
        .map((type) => type.placeholder)
        .toSet();
    final placeholders = _placeholderPattern
        .allMatches(fingerprint)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    if (placeholders.any(
          (placeholder) => !knownPlaceholders.contains(placeholder),
        ) ||
        placeholders.length != fieldPositionMetadata.fields.length) {
      throw const FormatException(
        'Notification fingerprint contains invalid typed fields.',
      );
    }
    for (final type in NotificationTemplateFieldType.values) {
      final fingerprintCount = placeholders
          .where((placeholder) => placeholder == type.placeholder)
          .length;
      final metadataCount = fieldPositionMetadata.fields
          .where((field) => field.type == type)
          .length;
      if (fingerprintCount != metadataCount) {
        throw const FormatException(
          'Notification field roles do not match their fingerprint.',
        );
      }
    }
    for (final field in fieldPositionMetadata.fields) {
      if (field.tokenIndex >= tokens.length ||
          !tokens[field.tokenIndex].contains(field.type.placeholder)) {
        throw FormatException(
          'Notification field ${field.type.placeholder} at token '
          '${field.tokenIndex} does not match a '
          '${tokens.length}-token fingerprint.',
        );
      }
    }
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

  /// Removes sensitive notification text as soon as it is no longer needed
  /// for user review. Hashes and non-content metadata remain available for
  /// deduplication and the local audit trail.
  Future<int> redactNonReviewRawNotificationPayloads() async {
    final pendingReviewRawIds = (await getTransactionsForReview())
        .map((review) => review.rawEvent.id)
        .whereType<int>()
        .toList();
    final placeholders = List.filled(pendingReviewRawIds.length, '?').join(',');
    final reviewExclusion = pendingReviewRawIds.isEmpty
        ? ''
        : 'AND id NOT IN ($placeholders)';
    final db = await database;
    return db.update(
      tableRawNotificationEvents,
      {'title': null, 'content': null},
      where: '(title IS NOT NULL OR content IS NOT NULL) $reviewExclusion',
      whereArgs: pendingReviewRawIds,
    );
  }

  Future<int> createParsedFinancialEvent(ParsedFinancialEvent event) async {
    final db = await database;
    return db.insert(tableParsedFinancialEvents, event.toMap());
  }

  /// Persists bounded, value-free parser telemetry in the encrypted database.
  Future<int> createParserDiagnostic(ParserDiagnostic diagnostic) async {
    const maximumLocalDiagnostics = 500;
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert(tableParserDiagnostics, diagnostic.toMap());
      await txn.rawDelete(
        'DELETE FROM $tableParserDiagnostics WHERE id NOT IN '
        '(SELECT id FROM $tableParserDiagnostics '
        'ORDER BY observed_at DESC, id DESC LIMIT ?)',
        [maximumLocalDiagnostics],
      );
      return id;
    });
  }

  Future<List<ParserDiagnostic>> getParserDiagnostics({int limit = 500}) async {
    if (limit < 1 || limit > 500) {
      throw RangeError.range(limit, 1, 500, 'limit');
    }
    final db = await database;
    final rows = await db.query(
      tableParserDiagnostics,
      orderBy: 'observed_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(ParserDiagnostic.fromMap).toList(growable: false);
  }

  Future<int> clearParserDiagnostics() async {
    final db = await database;
    return db.delete(tableParserDiagnostics);
  }

  Future<int> postIngestedTransaction({
    required Transaction transaction,
    required int parsedFinancialEventId,
    required int transactionGroupId,
    required LedgerEventRole eventRole,
    required String? ledgerCategory,
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
          transactionGroupId: transactionGroupId,
          parsedFinancialEventId: parsedFinancialEventId,
          legacyTransactionId: transactionId,
          accountId: transaction.accountId,
          direction: transaction.type == TransactionType.credit
              ? FinancialDirection.credit
              : FinancialDirection.debit,
          amountMinor: majorToMinor(transaction.amount),
          currencyCode: 'INR',
          occurredAt: transaction.timestamp,
          eventRole: eventRole,
          category: ledgerCategory,
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

  /// Returns retained, transaction-like notifications that have enough parsed
  /// evidence for the user to correct, but have not affected the ledger yet.
  Future<List<ReviewTransaction>> getTransactionsForReview() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT p.*, r.id raw_id, r.package_name raw_package_name,
        r.notification_key raw_notification_key,
        r.notification_id raw_notification_id,
        r.notification_tag raw_notification_tag, r.title raw_title,
        r.content raw_content, r.posted_at raw_posted_at,
        r.ingested_at raw_ingested_at, r.payload_hash raw_payload_hash,
        r.parser_version raw_parser_version,
        r.processing_state raw_processing_state,
        r.structural_fingerprint raw_structural_fingerprint,
        r.supersedes_event_id raw_supersedes_event_id,
        r.exact_duplicate_of_event_id raw_exact_duplicate_of_event_id,
        r.duplicate_rationale raw_duplicate_rationale
      FROM $tableParsedFinancialEvents p
      JOIN $tableRawNotificationEvents r ON r.id = p.raw_notification_event_id
      WHERE p.parse_decision IN ('provisional', 'retainOnly')
        AND r.processing_state IN ('retained', 'parsed', 'failed')
        AND p.status IN ('completed', 'reversed', 'unknown')
        AND p.event_type NOT IN ('balanceAlert')
        AND NOT EXISTS (
          SELECT 1 FROM $tableParsedEventLedgerLinks link
          WHERE link.parsed_financial_event_id = p.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM $tableLedgerEntries l
          WHERE l.parsed_financial_event_id = p.id
        )
      ORDER BY COALESCE(p.transaction_occurred_at, r.posted_at) DESC, p.id DESC
    ''');
    return rows
        .map((row) {
          final parsed = ParsedFinancialEvent.fromMap(row);
          final raw = RawNotificationEvent.fromMap({
            'id': row['raw_id'],
            'package_name': row['raw_package_name'],
            'notification_key': row['raw_notification_key'],
            'notification_id': row['raw_notification_id'],
            'notification_tag': row['raw_notification_tag'],
            'title': row['raw_title'],
            'content': row['raw_content'],
            'posted_at': row['raw_posted_at'],
            'ingested_at': row['raw_ingested_at'],
            'payload_hash': row['raw_payload_hash'],
            'parser_version': row['raw_parser_version'],
            'processing_state': row['raw_processing_state'],
            'structural_fingerprint': row['raw_structural_fingerprint'],
            'supersedes_event_id': row['raw_supersedes_event_id'],
            'exact_duplicate_of_event_id':
                row['raw_exact_duplicate_of_event_id'],
            'duplicate_rationale': row['raw_duplicate_rationale'],
          });
          return ReviewTransaction(parsedEvent: parsed, rawEvent: raw);
        })
        .where(_isTransactionLikeReviewCandidate)
        .toList();
  }

  bool _isTransactionLikeReviewCandidate(ReviewTransaction review) {
    return _isReviewableParsedEvent(review.parsedEvent);
  }

  bool _isReviewableParsedEvent(ParsedFinancialEvent parsed) {
    final transactionPhrase = parsed.fieldConfidence['transactionPhrase'] ?? 0;
    final reviewableDecision =
        parsed.parseDecision == ParseDecision.provisional ||
        parsed.parseDecision == ParseDecision.retainOnly;
    final reviewableStatus =
        parsed.status == FinancialEventStatus.completed ||
        parsed.status == FinancialEventStatus.reversed ||
        parsed.status == FinancialEventStatus.unknown;
    return reviewableDecision &&
        reviewableStatus &&
        parsed.eventType != FinancialEventType.balanceAlert &&
        transactionPhrase >= .75 &&
        parsed.failureCode != 'non_financial_or_sensitive' &&
        parsed.failureCode != 'non_posting_financial_alert';
  }

  /// Dismisses a review candidate without deleting its local audit evidence.
  ///
  /// The raw event is marked ignored, which removes it from the inbox while
  /// preserving the notification and parse result for local diagnostics.
  Future<void> dismissReviewedTransaction(int parsedFinancialEventId) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT p.*, r.processing_state raw_processing_state
        FROM $tableParsedFinancialEvents p
        JOIN $tableRawNotificationEvents r
          ON r.id = p.raw_notification_event_id
        WHERE p.id = ?
        LIMIT 1
        ''',
        [parsedFinancialEventId],
      );
      if (rows.isEmpty) {
        throw StateError('Review item is no longer available.');
      }
      final parsed = ParsedFinancialEvent.fromMap(rows.single);
      if (!_isReviewableState(rows.single['raw_processing_state'] as String) ||
          !_isReviewableParsedEvent(parsed)) {
        throw StateError('Review item is no longer available.');
      }
      await _ensureReviewIsUnresolved(txn, parsedFinancialEventId);
      await txn.rawUpdate(
        '''
        UPDATE $tableRawNotificationEvents
        SET processing_state = 'ignored', title = NULL, content = NULL
        WHERE id = (
          SELECT raw_notification_event_id
          FROM $tableParsedFinancialEvents
          WHERE id = ?
        )
        ''',
        [parsedFinancialEventId],
      );
    });
  }

  /// Posts a user-confirmed review item and links it to the original parsed
  /// notification in one transaction, removing it from the review inbox.
  Future<int> resolveReviewedTransaction({
    required int parsedFinancialEventId,
    required Transaction transaction,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final parsedRows = await txn.rawQuery(
        '''
        SELECT p.*, r.processing_state raw_processing_state
        FROM $tableParsedFinancialEvents p
        JOIN $tableRawNotificationEvents r
          ON r.id = p.raw_notification_event_id
        WHERE p.id = ?
        LIMIT 1
        ''',
        [parsedFinancialEventId],
      );
      if (parsedRows.isEmpty) {
        throw StateError('Review item is no longer available.');
      }
      final parsed = ParsedFinancialEvent.fromMap(parsedRows.single);
      if (!_isReviewableState(
            parsedRows.single['raw_processing_state'] as String,
          ) ||
          !_isReviewableParsedEvent(parsed)) {
        throw StateError('Review item is no longer available.');
      }
      await _ensureReviewIsUnresolved(txn, parsedFinancialEventId);

      final amountMinor = majorToMinor(transaction.amount);
      if (amountMinor <= 0) {
        throw ArgumentError.value(
          transaction.amount,
          'transaction.amount',
          'Reviewed transaction amount must be positive.',
        );
      }
      final now = DateTime.now().toUtc();
      final group = await _resolveReviewGroup(
        txn,
        parsed: parsed,
        transaction: transaction,
        amountMinor: amountMinor,
        now: now,
      );
      final eventRole = _reviewLedgerRole(parsed.eventType);
      final ledgerCategory = _reviewLedgerCategory(
        eventType: parsed.eventType,
        selectedCategory: transaction.category,
        groupCategory: group.category,
      );
      final storedTransaction = transaction.copyWith(
        category: ledgerCategory ?? 'Uncategorized',
      );
      final transactionId = await txn.insert(
        tableTransactions,
        storedTransaction.toMap(),
      );
      final ledgerId = await txn.insert(
        tableLedgerEntries,
        LedgerEntry(
          transactionGroupId: group.id,
          parsedFinancialEventId: parsedFinancialEventId,
          legacyTransactionId: transactionId,
          accountId: storedTransaction.accountId,
          direction: storedTransaction.type == TransactionType.credit
              ? FinancialDirection.credit
              : FinancialDirection.debit,
          amountMinor: amountMinor,
          currencyCode: 'INR',
          occurredAt: storedTransaction.timestamp,
          eventRole: eventRole,
          category: ledgerCategory,
          merchant: storedTransaction.merchant,
          createdAt: now,
        ).toMap(),
      );
      await txn.insert(tableParsedEventLedgerLinks, {
        'parsed_financial_event_id': parsedFinancialEventId,
        'ledger_entry_id': ledgerId,
        'match_rationale': 'userConfirmedReview',
        'confidence': 1.0,
        'created_at': now.toIso8601String(),
      });
      await txn.insert(tableParsedEventGroupLinks, {
        'parsed_financial_event_id': parsedFinancialEventId,
        'transaction_group_id': group.id,
        'match_rationale': 'userConfirmedReview',
        'confidence': 1.0,
        'created_at': now.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.rawUpdate(
        '''UPDATE $tableRawNotificationEvents
           SET processing_state = 'posted', title = NULL, content = NULL
           WHERE id = (SELECT raw_notification_event_id
                       FROM $tableParsedFinancialEvents WHERE id = ?)''',
        [parsedFinancialEventId],
      );
      await _rebuildAccountBalance(txn, storedTransaction.accountId);
      return transactionId;
    });
  }

  bool _isReviewableState(String state) =>
      state == RawNotificationProcessingState.retained.storageValue ||
      state == RawNotificationProcessingState.parsed.storageValue ||
      state == RawNotificationProcessingState.failed.storageValue;

  Future<void> _ensureReviewIsUnresolved(
    DatabaseExecutor txn,
    int parsedFinancialEventId,
  ) async {
    final alreadyLinked = await txn.rawQuery(
      '''
      SELECT 1
      FROM $tableParsedEventLedgerLinks
      WHERE parsed_financial_event_id = ?
      UNION ALL
      SELECT 1
      FROM $tableLedgerEntries
      WHERE parsed_financial_event_id = ?
      LIMIT 1
      ''',
      [parsedFinancialEventId, parsedFinancialEventId],
    );
    if (alreadyLinked.isNotEmpty) {
      throw StateError('Review item has already been resolved.');
    }
  }

  Future<TransactionGroup> _resolveReviewGroup(
    DatabaseExecutor txn, {
    required ParsedFinancialEvent parsed,
    required Transaction transaction,
    required int amountMinor,
    required DateTime now,
  }) async {
    final relatedGroupId = await _findReviewRelatedGroupId(txn, parsed);
    if (relatedGroupId != null) {
      final rows = await txn.query(
        tableTransactionGroups,
        where: 'id = ?',
        whereArgs: [relatedGroupId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        var group = TransactionGroup.fromMap(rows.single);
        if (parsed.eventType == FinancialEventType.refund) {
          final completed = group.completedRefundAmountMinor + amountMinor;
          final refundable =
              group.refundableAmountMinor ?? group.originalAmountMinor;
          final exceedsRefundable =
              refundable != null && completed > refundable;
          final missingOriginal = group.originalAmountMinor == null;
          group = TransactionGroup(
            id: group.id,
            groupType: refundable == null
                ? TransactionGroupType.unknown
                : completed == refundable
                ? TransactionGroupType.purchaseRefund
                : TransactionGroupType.partialRefund,
            merchantNormalized: group.merchantNormalized,
            category: group.category,
            originalAmountMinor: group.originalAmountMinor,
            refundableAmountMinor: group.refundableAmountMinor,
            completedRefundAmountMinor: completed,
            netExpenseMinor: (group.originalAmountMinor ?? 0) - completed,
            transferType: group.transferType,
            isInconsistent:
                group.isInconsistent || missingOriginal || exceedsRefundable,
            inconsistencyReason: missingOriginal
                ? 'refund_original_purchase_unidentified'
                : exceedsRefundable
                ? 'completed_refund_exceeds_refundable_amount'
                : group.inconsistencyReason,
            createdAt: group.createdAt,
            updatedAt: now,
          );
          await txn.update(
            tableTransactionGroups,
            group.toMap(),
            where: 'id = ?',
            whereArgs: [group.id],
          );
        } else if (parsed.eventType == FinancialEventType.reversal) {
          group = TransactionGroup(
            id: group.id,
            groupType: TransactionGroupType.reversal,
            merchantNormalized: group.merchantNormalized,
            category: group.category,
            originalAmountMinor: group.originalAmountMinor,
            refundableAmountMinor: group.refundableAmountMinor,
            completedRefundAmountMinor: group.completedRefundAmountMinor,
            netExpenseMinor: 0,
            transferType: group.transferType,
            isInconsistent: group.isInconsistent,
            inconsistencyReason: group.inconsistencyReason,
            createdAt: group.createdAt,
            updatedAt: now,
          );
          await txn.update(
            tableTransactionGroups,
            group.toMap(),
            where: 'id = ?',
            whereArgs: [group.id],
          );
        }
        return group;
      }
    }

    final direction = transaction.type == TransactionType.credit
        ? FinancialDirection.credit
        : FinancialDirection.debit;
    final eventRole = _reviewLedgerRole(parsed.eventType);
    final groupType = _reviewGroupType(parsed.eventType);
    final countsAsExpense =
        direction == FinancialDirection.debit &&
        eventRole == LedgerEventRole.primary &&
        groupType != TransactionGroupType.transfer;
    final isRefund = parsed.eventType == FinancialEventType.refund;
    final isReversal = parsed.eventType == FinancialEventType.reversal;
    final group = TransactionGroup(
      groupType: groupType,
      merchantNormalized:
          parsed.merchantNormalized ??
          transaction.merchant.trim().toLowerCase(),
      category: _reviewLedgerCategory(
        eventType: parsed.eventType,
        selectedCategory: transaction.category,
      ),
      originalAmountMinor: countsAsExpense ? amountMinor : null,
      refundableAmountMinor: countsAsExpense ? amountMinor : null,
      completedRefundAmountMinor: isRefund ? amountMinor : 0,
      netExpenseMinor: isRefund
          ? -amountMinor
          : countsAsExpense
          ? amountMinor
          : 0,
      transferType: groupType == TransactionGroupType.transfer
          ? TransferType.external
          : null,
      isInconsistent: isRefund || isReversal,
      inconsistencyReason: isRefund
          ? 'refund_original_purchase_unidentified'
          : isReversal
          ? 'reversal_original_transaction_unidentified'
          : null,
      createdAt: now,
      updatedAt: now,
    );
    final groupId = await txn.insert(tableTransactionGroups, group.toMap());
    return TransactionGroup(
      id: groupId,
      groupType: group.groupType,
      merchantNormalized: group.merchantNormalized,
      category: group.category,
      originalAmountMinor: group.originalAmountMinor,
      refundableAmountMinor: group.refundableAmountMinor,
      completedRefundAmountMinor: group.completedRefundAmountMinor,
      netExpenseMinor: group.netExpenseMinor,
      transferType: group.transferType,
      isInconsistent: group.isInconsistent,
      inconsistencyReason: group.inconsistencyReason,
      createdAt: group.createdAt,
      updatedAt: group.updatedAt,
    );
  }

  Future<int?> _findReviewRelatedGroupId(
    DatabaseExecutor txn,
    ParsedFinancialEvent parsed,
  ) async {
    final directLinks = await txn.query(
      tableParsedEventGroupLinks,
      columns: ['transaction_group_id'],
      where: 'parsed_financial_event_id = ?',
      whereArgs: [parsed.id],
      orderBy: 'confidence DESC, created_at ASC',
      limit: 1,
    );
    if (directLinks.isNotEmpty) {
      return directLinks.single['transaction_group_id'] as int;
    }
    if (parsed.eventType != FinancialEventType.refund &&
        parsed.eventType != FinancialEventType.reversal &&
        parsed.eventType != FinancialEventType.transfer) {
      return null;
    }
    final reference = parsed.referenceNumber?.trim();
    if (reference == null || reference.isEmpty) return null;
    final rows = await txn.rawQuery(
      '''
      SELECT peg.transaction_group_id
      FROM $tableParsedEventGroupLinks peg
      JOIN $tableParsedFinancialEvents candidate
        ON candidate.id = peg.parsed_financial_event_id
      WHERE candidate.id != ?
        AND LOWER(TRIM(candidate.reference_number)) = LOWER(TRIM(?))
      ORDER BY peg.confidence DESC, candidate.id DESC
      LIMIT 1
      ''',
      [parsed.id, reference],
    );
    return rows.isEmpty ? null : rows.single['transaction_group_id'] as int;
  }

  LedgerEventRole _reviewLedgerRole(FinancialEventType eventType) =>
      switch (eventType) {
        FinancialEventType.refund => LedgerEventRole.refund,
        FinancialEventType.reversal => LedgerEventRole.reversal,
        FinancialEventType.fee => LedgerEventRole.fee,
        _ => LedgerEventRole.primary,
      };

  TransactionGroupType _reviewGroupType(FinancialEventType eventType) =>
      switch (eventType) {
        FinancialEventType.purchase => TransactionGroupType.purchase,
        FinancialEventType.refund => TransactionGroupType.unknown,
        FinancialEventType.reversal => TransactionGroupType.reversal,
        FinancialEventType.transfer => TransactionGroupType.transfer,
        FinancialEventType.authorization =>
          TransactionGroupType.authorizationCompletion,
        FinancialEventType.cashback => TransactionGroupType.cashbackRelated,
        _ => TransactionGroupType.unknown,
      };

  String? _reviewLedgerCategory({
    required FinancialEventType eventType,
    required String selectedCategory,
    String? groupCategory,
  }) {
    if (eventType == FinancialEventType.refund ||
        eventType == FinancialEventType.reversal) {
      final category = groupCategory ?? selectedCategory;
      return category.trim().toLowerCase() == 'salary' ? null : category;
    }
    return selectedCategory;
  }

  /// Returns the lifecycle group already associated with a ledger entry.
  ///
  /// Older notification-created rows may not have [transaction_group_id]
  /// populated, so the parsed-event link is used as a migration-safe fallback.
  Future<int?> getTransactionGroupIdForLedgerEntry(int ledgerEntryId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(
        l.transaction_group_id,
        (
          SELECT peg.transaction_group_id
          FROM $tableParsedEventLedgerLinks pel
          JOIN $tableParsedEventGroupLinks peg
            ON peg.parsed_financial_event_id =
               pel.parsed_financial_event_id
          WHERE pel.ledger_entry_id = l.id
          ORDER BY peg.confidence DESC, peg.created_at ASC
          LIMIT 1
        ),
        (
          SELECT peg.transaction_group_id
          FROM $tableParsedEventGroupLinks peg
          WHERE peg.parsed_financial_event_id =
                l.parsed_financial_event_id
          ORDER BY peg.confidence DESC, peg.created_at ASC
          LIMIT 1
        )
      ) AS transaction_group_id
      FROM $tableLedgerEntries l
      WHERE l.id = ?
      LIMIT 1
      ''',
      [ledgerEntryId],
    );
    if (rows.isEmpty) return null;
    return rows.single['transaction_group_id'] as int?;
  }

  /// Repairs lifecycle metadata on an existing ledger entry without changing
  /// its monetary effect. This is used when a duplicate notification reveals
  /// a group link for a row created by an older app version.
  Future<void> updateLedgerLifecycle({
    required int ledgerEntryId,
    required int transactionGroupId,
    required LedgerEventRole eventRole,
    required String? category,
  }) async {
    final db = await database;
    await db.update(
      tableLedgerEntries,
      {
        'transaction_group_id': transactionGroupId,
        'event_role': eventRole.storageValue,
        'category': category,
      },
      where: 'id = ?',
      whereArgs: [ledgerEntryId],
    );
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
