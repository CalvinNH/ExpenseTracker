import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
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
      'expense_tracker_diagnostics_migration_',
    );
    AppDatabase.databasePathOverrideForTesting =
        '${tempDirectory.path}${Platform.pathSeparator}migration.db';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.databasePathOverrideForTesting = null;
    tempDirectory.deleteSync(recursive: true);
  });

  test(
    'v10 to v11 adds diagnostics table without changing ledger rows',
    () async {
      final db = await AppDatabase.instance.database;
      await db.execute('DROP TABLE parser_diagnostics');
      await db.insert(AppDatabase.tableAccounts, {
        'id': 41,
        'display_name': 'Migration Account',
        'account_type': 'bankAccount',
        'is_provisional': 0,
        'opening_balance_minor': 12345,
        'currency_code': 'INR',
        'created_at': DateTime.utc(2026, 8, 2).toIso8601String(),
        'current_balance': 123.45,
      });
      await db.setVersion(10);
      await AppDatabase.instance.close();

      final migrated = await AppDatabase.instance.database;
      expect(await migrated.getVersion(), 11);
      expect(await AppDatabase.instance.getAccount(41), isNotNull);
      final tables = await migrated.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [AppDatabase.tableParserDiagnostics],
      );
      expect(tables, hasLength(1));
    },
  );
}
