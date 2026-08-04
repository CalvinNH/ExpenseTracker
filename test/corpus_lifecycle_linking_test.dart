import 'dart:convert';
import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
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
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'HDFC Bank - 1234',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '1234',
      ),
    );
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Axis Bank - 9876',
        institutionId: 'axis',
        accountType: AccountType.bankAccount,
        lastFour: '9876',
      ),
    );
  });

  tearDown(() => AppDatabase.instance.close());

  test(
    'lifecycle fixtures link refunds, reversals, and duplicates safely',
    () async {
      final fixtures =
          (jsonDecode(
                    File(
                      'test/fixtures/parser_corpus/lifecycle_linking.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map<String, Object?>>();
      final processor = NotificationIngestionProcessor();
      final dispositions = <String, IngestionDisposition>{};

      for (var index = 0; index < fixtures.length; index++) {
        final fixture = fixtures[index];
        final result = await processor.ingest(
          NotificationEnvelope(
            packageName: fixture['sourcePackage']! as String,
            notificationId: fixture['notificationId']! as int,
            title: fixture['title']! as String,
            content: fixture['content']! as String,
            postedAt: DateTime.utc(2026, 8, 1).add(Duration(hours: index)),
            ingestedAt: DateTime.utc(2026, 8, 1).add(Duration(hours: index)),
          ),
        );
        dispositions[fixture['id']! as String] = result.disposition;
        expect(result.disposition.name, fixture['expectedDisposition']);
      }

      expect(
        dispositions['purchase_duplicate'],
        IngestionDisposition.sourceDuplicate,
      );
      final db = await AppDatabase.instance.database;
      final groups = (await db.query(
        AppDatabase.tableTransactionGroups,
      )).map(TransactionGroup.fromMap).toList();
      expect(
        groups.map((group) => group.groupType),
        containsAll(<TransactionGroupType>[
          TransactionGroupType.purchaseRefund,
          TransactionGroupType.reversal,
        ]),
      );
      final transactions = await AppDatabase.instance.getAllTransactions();
      expect(transactions, hasLength(4));
      final metricsDuplicateRate = 1 / fixtures.length;
      expect(metricsDuplicateRate, closeTo(1 / 6, 0.0001));
    },
  );
}
