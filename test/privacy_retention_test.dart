import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/parser_diagnostic.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_service.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
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

  test(
    'receipt prune preserves raw tombstone and late replay has no effect or UI signal',
    () async {
      final accountId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'HDFC Savings XX1234',
          institutionId: 'hdfc',
          accountType: AccountType.bankAccount,
          lastFour: '1234',
          openingBalanceMinor: 100000,
        ),
      );
      final processor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: 'com.google.android.apps.messaging',
        ),
      );
      final envelope = NotificationEnvelope(
        packageName: 'com.google.android.apps.messaging',
        captureReceiptId: 'device-hmac-receipt-retention',
        notificationId: 40,
        title: 'Transaction alert',
        content: 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
        postedAt: DateTime.utc(2025, 1, 1, 8),
        ingestedAt: DateTime.utc(2025, 1, 1, 8, 0, 1),
      );

      final committed = await processor.ingest(envelope);
      expect(committed.disposition, IngestionDisposition.posted);
      final db = await AppDatabase.instance.database;
      await db.update(
        AppDatabase.tableNotificationIngestionReceipts,
        {'completed_at': DateTime.utc(2025, 1, 1).toIso8601String()},
      );
      final beforeCounts = await _domainCounts();
      final balanceBefore = (await AppDatabase.instance.getAccount(
        accountId,
      ))!.currentBalance;

      final pruned = await AppDatabase.instance.prunePrivacyRetention(
        now: DateTime.utc(2026, 8, 10),
      );

      expect(pruned.ingestionReceipts, 1);
      expect(
        await _count(AppDatabase.tableNotificationIngestionReceipts),
        0,
      );
      final raw = await AppDatabase.instance.getRawNotificationEvent(
        committed.rawEventId!,
      );
      expect(raw?.captureReceiptId, 'device-hmac-receipt-retention');

      final replay = await processor.ingest(envelope);
      expect(replay.isReceiptReplay, isTrue);
      expect(replay.disposition, IngestionDisposition.posted);
      expect(replay.rawEventId, committed.rawEventId);
      expect(replay.transactionId, committed.transactionId);
      expect(await _domainCounts(), beforeCounts);
      expect(
        (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
        balanceBefore,
      );

      var transactionSignals = 0;
      var reviewSignals = 0;
      dispatchIngestionResult(
        result: replay,
        onTransactionIngested: () => transactionSignals++,
        onReviewInboxChanged: () => reviewSignals++,
      );
      expect(transactionSignals, 0);
      expect(reviewSignals, 0);
    },
  );

  test('retention is bounded, idempotent, and deletes no financial domain', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Cash',
        accountType: AccountType.cash,
        openingBalanceMinor: 50000,
      ),
    );
    await AppDatabase.instance.createParserDiagnostic(
      ParserDiagnostic(
        observedAt: DateTime.utc(2025, 1, 1),
        parserVersion: 3,
        extractorsUsed: const ['validator.default.v1'],
        decision: 'retainOnly',
        confidence: 0,
        failureCode: 'transaction_amount_missing',
        sourceCategory: 'unknownPackage',
        structuralFingerprint: 'must never be exported',
      ),
    );
    await AppDatabase.instance.createParserDiagnostic(
      ParserDiagnostic(
        observedAt: DateTime.utc(2026, 8, 9),
        parserVersion: 3,
        extractorsUsed: const ['validator.default.v1'],
        decision: 'retainOnly',
        confidence: 0,
        failureCode: 'transaction_amount_missing',
        sourceCategory: 'unknownPackage',
        structuralFingerprint: 'recent',
      ),
    );
    await AppDatabase.instance.createRawNotificationEvent(
      RawNotificationEvent(
        packageName: 'com.example.old',
        title: null,
        content: null,
        postedAt: DateTime.utc(2025, 1, 1),
        ingestedAt: DateTime.utc(2025, 1, 1),
        payloadHash: 'retired:orphan',
        parserVersion: 3,
        processingState: RawNotificationProcessingState.ignored,
      ),
    );
    final financialBefore = await _domainCounts();

    final first = await AppDatabase.instance.prunePrivacyRetention(
      now: DateTime.utc(2026, 8, 10),
    );
    final second = await AppDatabase.instance.prunePrivacyRetention(
      now: DateTime.utc(2026, 8, 10),
    );

    expect(first.parserDiagnostics, 1);
    expect(first.ignoredRawEvents, 1);
    expect(second.parserDiagnostics, 0);
    expect(second.ingestionReceipts, 0);
    expect(second.ignoredRawEvents, 0);
    expect(await _count(AppDatabase.tableParserDiagnostics), 1);
    expect(await _count(AppDatabase.tableRawNotificationEvents), 0);
    expect(await _domainCounts(), financialBefore);
  });
}

Future<int> _count(String table) async {
  final rows = await (await AppDatabase.instance.database).rawQuery(
    'SELECT COUNT(*) AS count FROM $table',
  );
  return (rows.single['count'] as num).toInt();
}

Future<Map<String, int>> _domainCounts() async => {
  for (final table in <String>[
    AppDatabase.tableAccounts,
    AppDatabase.tableTransactions,
    AppDatabase.tableTransactionGroups,
    AppDatabase.tableLedgerEntries,
    AppDatabase.tableParsedFinancialEvents,
    AppDatabase.tableParsedEventLedgerLinks,
    AppDatabase.tableParsedEventGroupLinks,
  ])
    table: await _count(table),
};
