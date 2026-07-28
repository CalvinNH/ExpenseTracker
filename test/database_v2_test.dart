import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await AppDatabase.instance.close();
    tempDirectory = await Directory.systemTemp.createTemp(
      'expense_tracker_v2_',
    );
    AppDatabase.databasePathOverrideForTesting =
        '${tempDirectory.path}${Platform.pathSeparator}test.db';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.databasePathOverrideForTesting = null;
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('fresh database creates current domain schema and indexes', () async {
    final db = await AppDatabase.instance.database;
    final version = await db.getVersion();
    expect(version, AppDatabase.databaseVersion);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tableNames = tables.map((row) => row['name']).toSet();
    expect(tableNames, contains(AppDatabase.tableAccounts));
    expect(tableNames, contains(AppDatabase.tableTransactions));
    expect(tableNames, contains(AppDatabase.tableRawNotificationEvents));
    expect(tableNames, contains(AppDatabase.tableParsedFinancialEvents));
    expect(tableNames, contains(AppDatabase.tableTransactionGroups));
    expect(tableNames, contains(AppDatabase.tableLedgerEntries));
    expect(tableNames, contains(AppDatabase.tableParsedEventLedgerLinks));
    expect(tableNames, contains(AppDatabase.tableParsedEventGroupLinks));

    final rawColumns = await db.rawQuery(
      'PRAGMA table_info(${AppDatabase.tableRawNotificationEvents})',
    );
    expect(
      rawColumns.map((row) => row['name']),
      containsAll(['exact_duplicate_of_event_id', 'duplicate_rationale']),
    );
    final parsedColumns = await db.rawQuery(
      'PRAGMA table_info(${AppDatabase.tableParsedFinancialEvents})',
    );
    expect(
      parsedColumns.map((row) => row['name']),
      containsAll([
        'payment_rail',
        'ledger_duplicate_confidence',
        'ledger_duplicate_rationale',
      ]),
    );

    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    );
    final indexNames = indexes.map((row) => row['name']).toSet();
    expect(indexNames, contains('idx_raw_notification_payload_hash'));
    expect(indexNames, contains('idx_raw_notification_package_posted'));
    expect(indexNames, contains('idx_parsed_reference_number'));
    expect(indexNames, contains('idx_ledger_account_occurred'));
    expect(indexNames, contains('idx_ledger_transaction_group'));
    expect(indexNames, contains('idx_parsed_instrument_last_four'));
    expect(indexNames, contains('idx_raw_supersedes'));
    expect(indexNames, contains('idx_ledger_legacy_transaction'));
    expect(indexNames, contains('idx_raw_exact_duplicate'));
    expect(indexNames, contains('idx_event_ledger_link'));
    expect(indexNames, contains('idx_event_group_link'));
  });

  test('version 1 upgrade preserves account and transaction data', () async {
    final path = AppDatabase.databasePathOverrideForTesting!;
    final legacyDb = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE accounts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bank_name TEXT NOT NULL,
              current_balance REAL NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE transactions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              amount REAL NOT NULL,
              type TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              merchant TEXT NOT NULL,
              category TEXT NOT NULL,
              account_id INTEGER NOT NULL,
              FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE
            )
          ''');
          await db.insert('accounts', {
            'id': 7,
            'bank_name': 'HDFC Credit Card XX4321',
            'current_balance': -1234.56,
          });
          await db.insert('transactions', {
            'id': 9,
            'amount': 234.56,
            'type': 'debit',
            'timestamp': DateTime.utc(2026, 7, 24).toIso8601String(),
            'merchant': 'Legacy Store',
            'category': 'Shopping',
            'account_id': 7,
          });
        },
      ),
    );
    await legacyDb.close();

    final migrated = await AppDatabase.instance.database;
    expect(await migrated.getVersion(), AppDatabase.databaseVersion);

    final account = await AppDatabase.instance.getAccount(7);
    expect(account, isNotNull);
    expect(account!.displayName, 'HDFC Credit Card XX4321');
    expect(account.bankName, account.displayName);
    expect(account.accountType, AccountType.creditCard);
    expect(account.lastFour, '4321');
    expect(account.openingBalanceMinor, -123456);
    expect(account.currentBalance, -1234.56);
    expect(account.currencyCode, 'INR');

    final transaction = await AppDatabase.instance.getTransaction(9);
    expect(transaction, isNotNull);
    expect(transaction!.merchant, 'Legacy Store');
    expect(transaction.amount, 234.56);
    expect(transaction.accountId, 7);

    final accountColumns = await migrated.rawQuery(
      'PRAGMA table_info(accounts)',
    );
    final columnNames = accountColumns.map((row) => row['name']).toSet();
    expect(columnNames, contains('display_name'));
    expect(columnNames, isNot(contains('bank_name')));

    final ledgerCountRows = await migrated.rawQuery(
      'SELECT COUNT(*) AS count FROM ledger_entries',
    );
    final ledgerCount = ledgerCountRows.first['count'] as int;
    expect(ledgerCount, 0, reason: 'legacy effects must not be duplicated');
  });

  test(
    'version 2 upgrade adds source supersession and ledger linkage',
    () async {
      final path = AppDatabase.databasePathOverrideForTesting!;
      final version2Db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await db.execute('''
            CREATE TABLE raw_notification_events (
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
              structural_fingerprint TEXT
            )
          ''');
            await db.execute('''
            CREATE TABLE ledger_entries (
              id INTEGER PRIMARY KEY AUTOINCREMENT
            )
          ''');
          },
        ),
      );
      await version2Db.close();

      final migrated = await AppDatabase.instance.database;
      expect(await migrated.getVersion(), AppDatabase.databaseVersion);
      final rawColumns = await migrated.rawQuery(
        'PRAGMA table_info(raw_notification_events)',
      );
      final ledgerColumns = await migrated.rawQuery(
        'PRAGMA table_info(ledger_entries)',
      );
      expect(
        rawColumns.map((row) => row['name']),
        contains('supersedes_event_id'),
      );
      expect(
        ledgerColumns.map((row) => row['name']),
        contains('legacy_transaction_id'),
      );
    },
  );

  test(
    'balance rebuild uses opening balance and posted ledger entries',
    () async {
      final accountId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'Cash',
          accountType: AccountType.cash,
          openingBalanceMinor: 100000,
          currencyCode: 'INR',
        ),
      );
      final now = DateTime.utc(2026, 7, 25, 12);

      await AppDatabase.instance.createLedgerEntry(
        LedgerEntry(
          accountId: accountId,
          direction: FinancialDirection.debit,
          amountMinor: 12550,
          currencyCode: 'INR',
          occurredAt: now,
          eventRole: LedgerEventRole.primary,
          createdAt: now,
        ),
      );
      await AppDatabase.instance.createLedgerEntry(
        LedgerEntry(
          accountId: accountId,
          direction: FinancialDirection.credit,
          amountMinor: 2000,
          currencyCode: 'INR',
          occurredAt: now,
          eventRole: LedgerEventRole.refund,
          createdAt: now,
        ),
      );
      await AppDatabase.instance.createLedgerEntry(
        LedgerEntry(
          accountId: accountId,
          direction: FinancialDirection.debit,
          amountMinor: 999,
          currencyCode: 'INR',
          occurredAt: now,
          eventRole: LedgerEventRole.primary,
          isProvisional: true,
          createdAt: now,
        ),
      );

      expect(
        await AppDatabase.instance.rebuildAccountBalance(accountId),
        89450,
      );
      final account = await AppDatabase.instance.getAccount(accountId);
      expect(account!.currentBalance, 894.50);
    },
  );

  test('foreign keys reject orphan financial and ledger events', () async {
    final now = DateTime.utc(2026, 7, 25);
    final orphanParsed = ParsedFinancialEvent(
      rawNotificationEventId: 999,
      eventType: FinancialEventType.purchase,
      status: FinancialEventStatus.completed,
      direction: FinancialDirection.debit,
      amountMinor: 100,
      currencyCode: 'INR',
      overallConfidence: 0.9,
      parseDecision: ParseDecision.autoPost,
    );
    expect(
      () => AppDatabase.instance.createParsedFinancialEvent(orphanParsed),
      throwsA(isA<DatabaseException>()),
    );

    final rawId = await AppDatabase.instance.createRawNotificationEvent(
      RawNotificationEvent(
        packageName: 'com.example.sms',
        title: 'Alert',
        content: 'Test',
        postedAt: now,
        ingestedAt: now,
        payloadHash: 'local-hash',
        parserVersion: 1,
        processingState: RawNotificationProcessingState.retained,
      ),
    );
    expect(rawId, greaterThan(0));

    expect(
      () => AppDatabase.instance.createLedgerEntry(
        LedgerEntry(
          accountId: 999,
          direction: FinancialDirection.debit,
          amountMinor: 100,
          currencyCode: 'INR',
          occurredAt: now,
          eventRole: LedgerEventRole.primary,
          createdAt: now,
        ),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });
}
