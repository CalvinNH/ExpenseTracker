import 'dart:async';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
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
    'a failure releases the current and every unprocessed claimed row',
    () async {
      final acknowledged = <String>[];
      final released = <String>[];
      final errors = <Object>[];
      final captures = <({String id, String lease})>[
        (id: 'already-processed', lease: 'lease-a'),
        (id: 'failed', lease: 'lease-a'),
        (id: 'unprocessed-a', lease: 'lease-a'),
        (id: 'unprocessed-b', lease: 'lease-b'),
      ];

      final outcome = await drainClaimedCaptureBatch(
        captures: captures,
        inboxIdOf: (capture) => capture.id,
        leaseTokenOf: (capture) => capture.lease,
        process: (capture) async {
          if (capture.id == 'failed') throw StateError('database locked');
        },
        acknowledge: (_, ids) async {
          acknowledged.addAll(ids);
          return ids.length;
        },
        release: (_, ids) async => released.addAll(ids),
        onError: (error, _) async => errors.add(error),
      );

      expect(outcome.completed, isFalse);
      expect(outcome.failureStage, CaptureBatchFailureStage.processing);
      expect(acknowledged, ['already-processed']);
      expect(
        released,
        unorderedEquals(['failed', 'unprocessed-a', 'unprocessed-b']),
      );
      expect(released, isNot(contains('already-processed')));
      expect(errors.single, isA<StateError>());
    },
  );

  test(
    'commit before failed native ack replays without a second effect or signal',
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
      final results = <IngestionResult>[];
      var transactionSignals = 0;
      var reviewSignals = 0;
      var ackAttempts = 0;
      var releases = 0;
      final errors = <Object>[];

      Future<void> process(String _) async {
        final result = await processor.ingest(
          NotificationEnvelope(
            packageName: 'com.google.android.apps.messaging',
            captureReceiptId: 'stable-native-event-hmac',
            notificationId: 10,
            title: 'Transaction alert',
            content: 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
            postedAt: DateTime.utc(2026, 8, 10, 9),
            ingestedAt: DateTime.utc(2026, 8, 10, 9, 0, 1),
          ),
        );
        results.add(result);
        dispatchIngestionResult(
          result: result,
          onTransactionIngested: () => transactionSignals++,
          onReviewInboxChanged: () => reviewSignals++,
        );
      }

      Future<CaptureBatchDrainOutcome> drainOnce() =>
          drainClaimedCaptureBatch<String>(
            captures: const ['native-inbox-row'],
            inboxIdOf: (capture) => capture,
            leaseTokenOf: (_) => 'lease',
            process: process,
            acknowledge: (_, _) async {
              ackAttempts++;
              if (ackAttempts == 1) throw StateError('ack response lost');
              return 1;
            },
            release: (_, _) async => releases++,
            onError: (error, _) async => errors.add(error),
          );

      expect((await drainOnce()).completed, isFalse);
      expect((await drainOnce()).completed, isTrue);

      expect(results, hasLength(2));
      expect(results.first.disposition, IngestionDisposition.posted);
      expect(results.first.isReceiptReplay, isFalse);
      expect(results.last.isReceiptReplay, isTrue);
      expect(results.last.rawEventId, results.first.rawEventId);
      expect(
        results.last.parsedFinancialEventId,
        results.first.parsedFinancialEventId,
      );
      expect(results.last.transactionId, results.first.transactionId);
      expect(transactionSignals, 1);
      expect(reviewSignals, 0);
      expect(ackAttempts, 2);
      expect(releases, 1);
      expect(errors.single, isA<StateError>());

      final db = await AppDatabase.instance.database;
      Future<int> count(String table) async =>
          ((await db.rawQuery(
                    'SELECT COUNT(*) count FROM $table',
                  )).single['count']
                  as num)
              .toInt();
      expect(await count(AppDatabase.tableRawNotificationEvents), 1);
      expect(await count(AppDatabase.tableParsedFinancialEvents), 1);
      expect(await count(AppDatabase.tableTransactionGroups), 1);
      expect(await count(AppDatabase.tableLedgerEntries), 1);
      expect(await count(AppDatabase.tableTransactions), 1);
      expect(await count(AppDatabase.tableNotificationIngestionReceipts), 1);
      expect(
        (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
        900,
      );
    },
  );

  test(
    'foreground and headless race has one ledger effect and one UI signal',
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
      final foregroundEntered = Completer<void>();
      final allowForegroundCommit = Completer<void>();
      final foregroundProcessor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: 'com.google.android.apps.messaging',
        ),
        faultInjectorForTesting: (checkpoint) async {
          if (checkpoint == IngestionFaultCheckpoint.beforeRawInsert) {
            foregroundEntered.complete();
            await allowForegroundCommit.future;
          }
        },
      );
      final headlessProcessor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: 'com.google.android.apps.messaging',
        ),
      );
      final envelope = NotificationEnvelope(
        packageName: 'com.google.android.apps.messaging',
        captureReceiptId: 'foreground-headless-race-receipt',
        notificationId: 11,
        title: 'Transaction alert',
        content: 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
        postedAt: DateTime.utc(2026, 8, 10, 10),
        ingestedAt: DateTime.utc(2026, 8, 10, 10, 0, 1),
      );

      final foreground = foregroundProcessor.ingest(envelope);
      await foregroundEntered.future;
      final headless = headlessProcessor.ingest(envelope);
      allowForegroundCommit.complete();
      final foregroundResult = await foreground;
      final headlessResult = await headless;

      var transactionSignals = 0;
      dispatchIngestionResult(
        result: foregroundResult,
        onTransactionIngested: () => transactionSignals++,
        onReviewInboxChanged: () {},
      );
      // Headless execution intentionally performs no dispatch.
      expect(foregroundResult.isReceiptReplay, isFalse);
      expect(headlessResult.isReceiptReplay, isTrue);
      expect(headlessResult.transactionId, foregroundResult.transactionId);
      expect(transactionSignals, 1);

      final db = await AppDatabase.instance.database;
      Future<int> count(String table) async =>
          ((await db.rawQuery(
                    'SELECT COUNT(*) count FROM $table',
                  )).single['count']
                  as num)
              .toInt();
      expect(await count(AppDatabase.tableTransactions), 1);
      expect(await count(AppDatabase.tableLedgerEntries), 1);
      expect(
        (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
        900,
      );
    },
  );

  test('captured time is used with invalid and future fallback', () {
    final now = DateTime.utc(2026, 8, 10, 10);
    final captured = now.subtract(const Duration(seconds: 3));

    expect(captureIngestedAt(captured.millisecondsSinceEpoch, now), captured);
    expect(captureIngestedAt(0, now), now);
    expect(
      captureIngestedAt(
        now.add(const Duration(minutes: 6)).millisecondsSinceEpoch,
        now,
      ),
      now,
    );
  });
}
