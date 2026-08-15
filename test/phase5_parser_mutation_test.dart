import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';
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

  test('safe formatting mutations preserve core transaction fields', () {
    final pipeline = NotificationParsingPipeline();
    const variants = <String>[
      'INR 481.25 debited from account XX1201 at DEMO CAFE Ref SYN520001',
      '  INR   481.25   DEBITED FROM ACCOUNT XX1201 AT DEMO CAFE REF SYN520001  ',
      'Rs. 481.25 debited from A/c **1201 at DEMO CAFE Ref SYN520001',
      'inr 481.25\ndebited from account xxxx1201\nat DEMO CAFE ref SYN520001',
    ];

    for (final content in variants) {
      final result = pipeline.parse(
        'Synthetic debit',
        content,
        sourcePackage: 'com.snapwork.hdfc',
        knownPackage: true,
      );
      expect(result.relevance, FinancialRelevance.transaction);
      expect(result.direction, FinancialDirection.debit);
      expect(result.status, FinancialEventStatus.completed);
      expect(result.selectedAmount?.amountMinor, 48125);
      expect(result.instrument.lastFour, '1201');
      expect(result.decision, ParseDecision.autoPost);
    }
  });

  test('same receipt and same-effect update never create a second effect', () async {
    final accountId = await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Synthetic Bank XX1201',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '1201',
        openingBalanceMinor: 100000,
      ),
    );
    final processor = NotificationIngestionProcessor(
      sourcePolicy: NotificationSourcePolicy(
        defaultSmsPackage: 'com.google.android.apps.messaging',
      ),
    );
    final first = await processor.ingest(
      NotificationEnvelope(
        packageName: 'com.snapwork.hdfc',
        captureReceiptId: 'synthetic-phase5-receipt-a',
        notificationKey: 'synthetic-phase5-update-key',
        notificationId: 520,
        title: 'Synthetic debit',
        content:
            'INR 481.25 debited from account XX1201 at DEMO CAFE Ref SYN520001',
        postedAt: DateTime.utc(2026, 8, 10, 10),
        ingestedAt: DateTime.utc(2026, 8, 10, 10, 0, 1),
      ),
    );
    final receiptReplay = await processor.ingest(
      NotificationEnvelope(
        packageName: 'com.snapwork.hdfc',
        captureReceiptId: 'synthetic-phase5-receipt-a',
        notificationKey: 'synthetic-phase5-update-key',
        notificationId: 520,
        title: 'Synthetic debit updated',
        content:
            'INR 481.25 DEBITED FROM ACCOUNT XX1201 AT DEMO CAFE REF SYN520001',
        postedAt: DateTime.utc(2026, 8, 10, 10),
        ingestedAt: DateTime.utc(2026, 8, 10, 10, 0, 2),
      ),
    );
    final sameEffectUpdate = await processor.ingest(
      NotificationEnvelope(
        packageName: 'com.snapwork.hdfc',
        captureReceiptId: 'synthetic-phase5-receipt-b',
        notificationKey: 'synthetic-phase5-update-key',
        notificationId: 520,
        title: 'Synthetic debit confirmed',
        content:
            'INR 481.25 debited from account XX1201 at DEMO CAFE Ref SYN520001.',
        postedAt: DateTime.utc(2026, 8, 10, 10),
        ingestedAt: DateTime.utc(2026, 8, 10, 10, 0, 3),
      ),
    );

    expect(first.disposition, IngestionDisposition.posted);
    expect(receiptReplay.isReceiptReplay, isTrue);
    expect(sameEffectUpdate.disposition, IngestionDisposition.sourceDuplicate);
    final transactions = await AppDatabase.instance.getAllTransactions();
    expect(transactions, hasLength(1));
    expect(
      (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
      closeTo(518.75, 0.001),
    );
  });
}
