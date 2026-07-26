import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final postedAt = DateTime.utc(2026, 7, 26, 8, 30);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await AppDatabase.instance.close();
    AppDatabase.databaseName = inMemoryDatabasePath;
    AppDatabase.databasePathOverrideForTesting = null;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  NotificationEnvelope envelope({
    required String packageName,
    int notificationId = 10,
    String title = 'Transaction alert',
    String content = 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
    DateTime? eventTime,
  }) {
    return NotificationEnvelope(
      packageName: packageName,
      notificationId: notificationId,
      title: title,
      content: content,
      postedAt: eventTime ?? postedAt,
      ingestedAt: (eventTime ?? postedAt).add(const Duration(seconds: 1)),
    );
  }

  Future<int> createHdfcAccount() {
    return AppDatabase.instance.createAccount(
      Account(
        displayName: 'HDFC Savings XX1234',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '1234',
        openingBalanceMinor: 100000,
      ),
    );
  }

  test('source policy accepts SMS, bank, and wallet packages', () {
    final policy = NotificationSourcePolicy(
      defaultSmsPackage: 'com.example.default.sms',
    );
    expect(
      policy.classify('com.example.default.sms'),
      NotificationSourceClass.defaultSmsPackage,
    );
    expect(
      policy.classify('com.snapwork.hdfc'),
      NotificationSourceClass.knownFinancialPackage,
    );
    expect(
      policy.classify('net.one97.paytm'),
      NotificationSourceClass.knownWalletPackage,
    );
    expect(
      policy.classify('com.application.zomato'),
      NotificationSourceClass.knownMerchantPackage,
    );
    expect(
      policy.classify('com.android.systemui'),
      NotificationSourceClass.ignoredPackage,
    );
    expect(
      policy.classify('com.example.unknown'),
      NotificationSourceClass.unknownPackage,
    );
  });

  test('known SMS package is persisted and posted', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor(
      sourcePolicy: NotificationSourcePolicy(
        defaultSmsPackage: 'com.example.default.sms',
      ),
    );

    final result = await processor.ingest(
      envelope(packageName: 'com.example.default.sms'),
    );

    expect(result.disposition, IngestionDisposition.posted);
    expect(
      (await AppDatabase.instance.getAllRawNotificationEvents()),
      hasLength(1),
    );
    final transactions = await AppDatabase.instance.getAllTransactions();
    expect(transactions, hasLength(1));
    expect(transactions.single.timestamp, postedAt);
  });

  test('known bank application is persisted and posted', () async {
    await createHdfcAccount();
    final result = await NotificationIngestionProcessor().ingest(
      envelope(packageName: 'com.snapwork.hdfc'),
    );

    expect(result.disposition, IngestionDisposition.posted);
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
  });

  test('known wallet application is persisted and posted safely', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Paytm Wallet',
        accountType: AccountType.wallet,
        sourcePackageHint: 'net.one97.paytm',
        openingBalanceMinor: 50000,
      ),
    );
    final result = await NotificationIngestionProcessor().ingest(
      envelope(
        packageName: 'net.one97.paytm',
        content: 'INR 50.00 paid at Cafe using wallet.',
      ),
    );

    expect(result.disposition, IngestionDisposition.posted);
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
  });

  test('unknown source without stronger evidence is retained', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Merchant-linked Wallet',
        sourcePackageHint: 'com.unknown.sender',
        accountType: AccountType.wallet,
        openingBalanceMinor: 10000,
      ),
    );
    final result = await NotificationIngestionProcessor().ingest(
      envelope(
        packageName: 'com.unknown.sender',
        content: 'Paid INR 100.00 at Cafe.',
      ),
    );

    expect(result.disposition, IngestionDisposition.retained);
    expect(result.diagnosticCode, 'unknown_source_insufficient_evidence');
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(1),
    );
    expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    final parsed = await AppDatabase.instance.getParsedFinancialEvent(
      result.parsedFinancialEventId!,
    );
    expect(parsed!.parseDecision, ParseDecision.retainOnly);
  });

  test(
    'explicitly ignored package is rejected without raw persistence',
    () async {
      final result = await NotificationIngestionProcessor().ingest(
        envelope(packageName: 'com.android.systemui'),
      );

      expect(result.disposition, IngestionDisposition.ignored);
      expect(await AppDatabase.instance.getAllRawNotificationEvents(), isEmpty);
    },
  );

  test(
    'notification removal callback is ignored without persistence',
    () async {
      final result = await NotificationIngestionProcessor().ingest(
        NotificationEnvelope(
          packageName: 'com.google.android.apps.messaging',
          notificationId: 10,
          title: 'Transaction alert',
          content: 'INR 100 debited from HDFC Bank A/c XX1234.',
          postedAt: postedAt,
          ingestedAt: postedAt,
          hasRemoved: true,
        ),
      );

      expect(result.disposition, IngestionDisposition.ignored);
      expect(result.diagnosticCode, 'notification_removed');
      expect(await AppDatabase.instance.getAllRawNotificationEvents(), isEmpty);
    },
  );

  test('parse failure is retained with its raw source evidence', () async {
    final result = await NotificationIngestionProcessor().ingest(
      envelope(
        packageName: 'com.google.android.apps.messaging',
        content: 'Your parcel will arrive today.',
      ),
    );

    expect(result.disposition, IngestionDisposition.retained);
    final rawEvents = await AppDatabase.instance.getAllRawNotificationEvents();
    expect(rawEvents, hasLength(1));
    expect(
      rawEvents.single.processingState,
      RawNotificationProcessingState.failed,
    );
    final parsed = await AppDatabase.instance.getParsedFinancialEvent(
      result.parsedFinancialEventId!,
    );
    expect(parsed!.failureCode, 'parser_no_match');
  });

  test('identical notification is not processed twice', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    final notification = envelope(
      packageName: 'com.google.android.apps.messaging',
    );

    final first = await processor.ingest(notification);
    final second = await processor.ingest(notification);

    expect(first.disposition, IngestionDisposition.posted);
    expect(second.disposition, IngestionDisposition.duplicate);
    expect(second.rawEventId, first.rawEventId);
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(1),
    );
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
  });

  test(
    'updated notification content creates a superseding source event',
    () async {
      await createHdfcAccount();
      final processor = NotificationIngestionProcessor();
      final first = await processor.ingest(
        envelope(packageName: 'com.google.android.apps.messaging'),
      );
      final second = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          content: 'INR 125.00 debited from HDFC Bank A/c XX1234 at Cafe.',
        ),
      );

      expect(first.disposition, IngestionDisposition.posted);
      expect(second.disposition, IngestionDisposition.posted);
      final rawEvents = await AppDatabase.instance
          .getAllRawNotificationEvents();
      expect(rawEvents, hasLength(2));
      expect(rawEvents.last.supersedesEventId, rawEvents.first.id);
      expect(rawEvents.last.payloadHash, isNot(rawEvents.first.payloadHash));
      expect(await AppDatabase.instance.getAllTransactions(), hasLength(2));
    },
  );

  test('unresolved account never falls back to the first account', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Unrelated Cash',
        accountType: AccountType.cash,
        openingBalanceMinor: 10000,
      ),
    );
    final result = await NotificationIngestionProcessor().ingest(
      envelope(
        packageName: 'com.google.android.apps.messaging',
        content: 'INR 100.00 paid using UPI at Cafe.',
      ),
    );

    expect(result.disposition, IngestionDisposition.provisional);
    expect(result.diagnosticCode, 'account_unresolved');
    expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    final parsed = await AppDatabase.instance.getParsedFinancialEvent(
      result.parsedFinancialEventId!,
    );
    expect(parsed!.parseDecision, ParseDecision.provisional);
  });
}
