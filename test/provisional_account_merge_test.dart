import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
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
    tempDirectory = await Directory.systemTemp.createTemp('account_merge_');
    AppDatabase.databasePathOverrideForTesting =
        '${tempDirectory.path}${Platform.pathSeparator}test.db';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.databasePathOverrideForTesting = null;
    tempDirectory.deleteSync(recursive: true);
  });

  test(
    'provisional merge preserves balance, ledger, and audit trail',
    () async {
      final confirmedId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'SBI confirmed',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          openingBalanceMinor: 10000,
        ),
      );
      final provisionalId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'SBI account ending 3482',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          lastFour: '3482',
          isProvisional: true,
          openingBalanceMinor: 2000,
        ),
      );
      await AppDatabase.instance.createLedgerEntry(
        LedgerEntry(
          accountId: provisionalId,
          direction: FinancialDirection.credit,
          amountMinor: 500,
          currencyCode: 'INR',
          occurredAt: DateTime.utc(2026, 7, 1),
          eventRole: LedgerEventRole.primary,
          createdAt: DateTime.utc(2026, 7, 1),
        ),
      );

      await AppDatabase.instance.mergeProvisionalAccount(
        provisionalAccountId: provisionalId,
        confirmedAccountId: confirmedId,
      );

      expect(await AppDatabase.instance.getAccount(provisionalId), isNull);
      final confirmed = await AppDatabase.instance.getAccount(confirmedId);
      expect(confirmed?.openingBalanceMinor, 12000);
      expect(confirmed?.currentBalance, 125);
      final db = await AppDatabase.instance.database;
      final ledger = await db.query(
        AppDatabase.tableLedgerEntries,
        where: 'account_id = ?',
        whereArgs: [confirmedId],
      );
      expect(ledger, hasLength(1));
      expect(await db.query(AppDatabase.tableAccountMerges), hasLength(1));
    },
  );
}
