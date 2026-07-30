import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await AppDatabase.instance.close();
    AppDatabase.databaseName = inMemoryDatabasePath;
    AppDatabase.databasePathOverrideForTesting = null;
  });

  tearDown(() => AppDatabase.instance.close());

  test('concurrent callers share a valid initialized database', () async {
    final handles = await Future.wait(
      List.generate(50, (_) => AppDatabase.instance.database),
    );
    expect(handles.every((handle) => handle.isOpen), isTrue);
    expect(handles.toSet(), hasLength(1));
    final foreignKeys = await handles.first.rawQuery('PRAGMA foreign_keys');
    expect(foreignKeys.single.values.single, 1);
  });

  test('high-volume concurrent ingestion writes are retained', () async {
    await AppDatabase.instance.createAccount(
      Account(displayName: 'SBI', accountType: AccountType.bankAccount),
    );
    final now = DateTime.utc(2026, 7, 29);
    await Future.wait(
      List.generate(
        200,
        (index) => AppDatabase.instance.createRawNotificationEvent(
          RawNotificationEvent(
            packageName: 'com.bank.stress',
            notificationKey: 'stress-$index',
            notificationId: index,
            postedAt: now.add(Duration(milliseconds: index)),
            ingestedAt: now.add(Duration(milliseconds: index)),
            title: 'Debit $index',
            content: 'INR ${index + 1}',
            payloadHash: 'hash-$index',
            parserVersion: 1,
            processingState: RawNotificationProcessingState.retained,
          ),
        ),
      ),
    );
    final db = await AppDatabase.instance.database;
    final count = await db.rawQuery(
      'SELECT COUNT(*) count FROM ${AppDatabase.tableRawNotificationEvents}',
    );
    expect(count.single['count'], 200);
  });

  test(
    'close followed by immediate reopen does not expose a closed handle',
    () async {
      final opening = AppDatabase.instance.database;
      final closing = AppDatabase.instance.close();
      await Future.wait<void>([opening.then((_) {}), closing]);
      final reopened = await AppDatabase.instance.database;
      expect(reopened.isOpen, isTrue);
      expect(
        await reopened.rawQuery('SELECT count(*) FROM sqlite_master'),
        isNotEmpty,
      );
    },
  );

  test(
    'bank suffix uses compact label without changing account type',
    () async {
      final id = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'Kotakk Mahindra Bank account ending 7890',
          institutionId: 'kotak',
          accountType: AccountType.bankAccount,
          lastFour: '7890',
        ),
      );
      final account = await AppDatabase.instance.getAccount(id);
      expect(account!.displayName, 'Kotak Mahindra Bank - 7890');
      expect(account.lastFour, '7890');
      expect(account.accountType, AccountType.bankAccount);
    },
  );
}
