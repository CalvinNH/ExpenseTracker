import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

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
    String? captureReceiptId,
    int notificationId = 10,
    String title = 'Transaction alert',
    String content = 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
    DateTime? eventTime,
  }) {
    return NotificationEnvelope(
      packageName: packageName,
      captureReceiptId: captureReceiptId,
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

  NotificationIngestionProcessor trustedSmsProcessor({
    IngestionFaultInjector? faultInjectorForTesting,
  }) => NotificationIngestionProcessor(
    sourcePolicy: NotificationSourcePolicy(
      defaultSmsPackage: 'com.google.android.apps.messaging',
    ),
    faultInjectorForTesting: faultInjectorForTesting,
  );

  Future<int> rowCount(String table) async {
    final rows = await (await AppDatabase.instance.database).rawQuery(
      'SELECT COUNT(*) AS row_count FROM $table',
    );
    return (rows.single['row_count'] as num).toInt();
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
      policy.classify('com.google.android.apps.messaging'),
      NotificationSourceClass.knownNonDefaultSmsPackage,
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
      policy.classify('com.google.android.gm'),
      NotificationSourceClass.bestEffortEmailPackage,
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

  test('known SMS package remains non-default without a reported default', () {
    expect(
      NotificationSourcePolicy().classify('com.samsung.android.messaging'),
      NotificationSourceClass.knownNonDefaultSmsPackage,
    );
    expect(
      NotificationSourcePolicy(
        defaultSmsPackage: '',
      ).classify('com.samsung.android.messaging'),
      NotificationSourceClass.knownNonDefaultSmsPackage,
    );
  });

  test('known non-default SMS package cannot auto-post', () async {
    await createHdfcAccount();
    final result = await NotificationIngestionProcessor(
      sourcePolicy: NotificationSourcePolicy(
        defaultSmsPackage: 'com.google.android.apps.messaging',
      ),
    ).ingest(envelope(packageName: 'com.samsung.android.messaging'));

    expect(result.disposition, IngestionDisposition.retained);
    expect(result.diagnosticCode, 'secondary_source_review_required');
    expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
  });

  test(
    'known SMS package cannot auto-post when default is unavailable',
    () async {
      await createHdfcAccount();
      final result = await NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(),
      ).ingest(envelope(packageName: 'com.samsung.android.messaging'));

      expect(result.disposition, IngestionDisposition.retained);
      expect(result.diagnosticCode, 'secondary_source_review_required');
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    },
  );

  test('known SMS package is persisted and posted', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor(
      sourcePolicy: NotificationSourcePolicy(
        defaultSmsPackage: 'com.example.default.sms',
      ),
    );

    final result = await processor.ingest(
      envelope(
        packageName: 'com.example.default.sms',
        captureReceiptId: 'native-capture-receipt-1',
      ),
    );

    expect(result.disposition, IngestionDisposition.posted);
    final rawEvents = await AppDatabase.instance.getAllRawNotificationEvents();
    expect(rawEvents, hasLength(1));
    expect(rawEvents.single.title, isNull);
    expect(rawEvents.single.content, isNull);
    expect(rawEvents.single.payloadHash, isNotEmpty);
    expect(rawEvents.single.packageName, 'com.example.default.sms');
    expect(rawEvents.single.captureReceiptId, 'native-capture-receipt-1');
    expect(rawEvents.single.parserVersion, 3);
    final parsed = await AppDatabase.instance.getParsedFinancialEvent(
      result.parsedFinancialEventId!,
    );
    expect(
      parsed?.classificationMetadata,
      contains('"classifierId":"deterministic_semantic"'),
    );
    expect(parsed?.classificationMetadata, contains('"modelVersion":null'));
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

  test(
    'resolved primary account cannot upgrade a provisional parser decision',
    () async {
      await createHdfcAccount();
      final processor = NotificationIngestionProcessor(
        parsingPipeline: NotificationParsingPipeline(
          validator: const _AlwaysProvisionalValidator(),
        ),
      );

      final result = await processor.ingest(
        envelope(packageName: 'com.snapwork.hdfc'),
      );
      final parsed = await AppDatabase.instance.getParsedFinancialEvent(
        result.parsedFinancialEventId!,
      );

      expect(result.disposition, IngestionDisposition.provisional);
      expect(parsed?.parseDecision, ParseDecision.provisional);
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    },
  );

  test(
    'auto-created provisional account never receives an auto-post',
    () async {
      final result = await trustedSmsProcessor().ingest(
        envelope(packageName: 'com.google.android.apps.messaging'),
      );

      final accounts = await AppDatabase.instance.getAllAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.single.isProvisional, isTrue);
      expect(result.disposition, IngestionDisposition.provisional);
      expect(result.diagnosticCode, 'account_confirmation_required');
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    },
  );

  test(
    'HDFC card spent alert posts from SMS with card and ISO timestamp',
    () async {
      final accountId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'HDFC Credit Card - 2613',
          institutionId: 'hdfc',
          accountType: AccountType.creditCard,
          lastFour: '2613',
        ),
      );
      final processor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: 'com.google.android.apps.messaging',
        ),
      );

      final result = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          notificationId: 2613,
          title: 'HDFC Bank',
          content:
              'Spent Rs.441 On HDFC Bank Card 2613 At SWIGGY PVT LTD GROCE '
              'On 2026-08-04:21:50:19.Not You? To Block+Reissue Call '
              '18002586161/SMS BLOCK CC 2613 to 7308080808',
        ),
      );

      expect(result.disposition, IngestionDisposition.posted);
      final parsed = await AppDatabase.instance.getParsedFinancialEvent(
        result.parsedFinancialEventId!,
      );
      expect(parsed?.amountMinor, 44100);
      expect(parsed?.instrumentLastFour, '2613');
      expect(parsed?.merchantNormalized, 'Swiggy');
      expect(parsed?.transactionOccurredAt, DateTime(2026, 8, 4, 21, 50, 19));
      final transactions = await AppDatabase.instance.getAllTransactions();
      expect(transactions, hasLength(1));
      expect(transactions.single.accountId, accountId);
      expect(transactions.single.amount, 441);
      expect(transactions.single.timestamp, DateTime(2026, 8, 4, 21, 50, 19));
    },
  );

  test(
    'injected classifier provenance is stored but validation remains authoritative',
    () async {
      await createHdfcAccount();
      final processor = NotificationIngestionProcessor(
        parsingPipeline: NotificationParsingPipeline(
          notificationClassifier: const _FixtureBundledClassifier(),
        ),
      );

      final result = await processor.ingest(
        envelope(
          packageName: 'com.snapwork.hdfc',
          content:
              'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe failed.',
        ),
      );
      final parsed = await AppDatabase.instance.getParsedFinancialEvent(
        result.parsedFinancialEventId!,
      );

      expect(result.disposition, IngestionDisposition.retained);
      expect(parsed?.status, FinancialEventStatus.failed);
      expect(parsed?.parseDecision, ParseDecision.retainOnly);
      expect(
        parsed?.classificationMetadata,
        contains('"modelVersion":"fixture-model-v1"'),
      );
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    },
  );

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

  test(
    'email and merchant evidence is retain-only and never auto-posts',
    () async {
      final accountId = await createHdfcAccount();
      final processor = NotificationIngestionProcessor();

      for (final packageName in <String>[
        'com.google.android.gm',
        'com.application.zomato',
      ]) {
        final result = await processor.ingest(
          envelope(
            packageName: packageName,
            notificationId: packageName.hashCode,
          ),
        );

        expect(result.disposition, IngestionDisposition.retained);
        expect(result.diagnosticCode, 'secondary_source_review_required');
        final parsed = await AppDatabase.instance.getParsedFinancialEvent(
          result.parsedFinancialEventId!,
        );
        expect(parsed?.parseDecision, ParseDecision.retainOnly);
      }
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
      expect(await AppDatabase.instance.getParsedEventLedgerLinks(), isEmpty);
      expect(await AppDatabase.instance.getAllAccounts(), hasLength(1));
      expect(
        (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
        1000,
      );
    },
  );

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
    'a reviewed retained event moves into the resolved transaction ledger',
    () async {
      final accountId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'Review account',
          accountType: AccountType.bankAccount,
          openingBalanceMinor: 100000,
        ),
      );
      final result = await NotificationIngestionProcessor().ingest(
        envelope(
          packageName: 'com.unknown.sender',
          content: 'Paid INR 100.00 at Cafe.',
        ),
      );
      expect(result.disposition, IngestionDisposition.retained);
      final reviews = await AppDatabase.instance.getTransactionsForReview();
      expect(reviews, hasLength(1));
      expect(reviews.single.suggestedOccurredAt, postedAt);
      expect(reviews.single.parsedEvent.amountMinor, 10000);

      await AppDatabase.instance.resolveReviewedTransaction(
        parsedFinancialEventId: reviews.single.parsedEvent.id!,
        transaction: Transaction(
          amount: 100,
          type: TransactionType.debit,
          timestamp: reviews.single.suggestedOccurredAt,
          merchant: 'Cafe',
          category: 'Food & Dining',
          accountId: accountId,
        ),
      );

      expect(await AppDatabase.instance.getTransactionsForReview(), isEmpty);
      expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
      expect(
        await AppDatabase.instance.getParsedEventLedgerLinks(),
        hasLength(1),
      );
      final movements = await AppDatabase.instance.getAccountLedgerMovements();
      expect(movements, hasLength(1));
      expect(movements.single.entry.transactionGroupId, isNotNull);
      expect(movements.single.entry.eventRole, LedgerEventRole.primary);
      expect(
        await AppDatabase.instance.getParsedEventGroupLinks(),
        hasLength(1),
      );
      final summary = await AppDatabase.instance.getFinancialSummary();
      expect(summary.grossExpensesMinor, 10000);
      expect(summary.netExpensesMinor, 10000);
      final raw = await AppDatabase.instance.getRawNotificationEvent(
        result.rawEventId!,
      );
      expect(raw?.title, isNull);
      expect(raw?.content, isNull);
    },
  );

  test(
    'Paytm wallet notification with a transaction ID posts safely',
    () async {
      await AppDatabase.instance.createAccount(
        Account(
          displayName: 'Paytm Wallet',
          institutionId: 'paytm_wallet',
          accountType: AccountType.wallet,
          openingBalanceMinor: 10000,
        ),
      );
      final result = await NotificationIngestionProcessor().ingest(
        envelope(
          packageName: 'net.one97.paytm',
          title: 'Paytm',
          content: 'Paid Rs.160 to Tea Stall. Transaction ID: 2026072911',
        ),
      );

      expect(result.disposition, IngestionDisposition.posted);
      expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
    },
  );

  test('shell-injected notification remains unknown and retain-only', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Paytm Wallet',
        institutionId: 'paytm_wallet',
        accountType: AccountType.wallet,
        openingBalanceMinor: 10000,
      ),
    );
    final result = await NotificationIngestionProcessor().ingest(
      envelope(
        packageName: 'com.android.shell',
        title: 'Paytm',
        content: 'Paid Rs.160 to Tea Stall. Transaction ID: 2026072911',
      ),
    );

    expect(result.disposition, IngestionDisposition.retained);
    expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
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

  test(
    'non-transaction parse failure retains metadata but redacts text',
    () async {
      final result = await NotificationIngestionProcessor().ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          title: 'Delivery update',
          content: 'Your parcel will arrive today.',
        ),
      );

      expect(result.disposition, IngestionDisposition.retained);
      final rawEvents = await AppDatabase.instance
          .getAllRawNotificationEvents();
      expect(rawEvents, hasLength(1));
      expect(
        rawEvents.single.processingState,
        RawNotificationProcessingState.failed,
      );
      expect(rawEvents.single.title, isNull);
      expect(rawEvents.single.content, isNull);
      expect(rawEvents.single.payloadHash, isNotEmpty);
      final parsed = await AppDatabase.instance.getParsedFinancialEvent(
        result.parsedFinancialEventId!,
      );
      expect(parsed!.failureCode, 'transaction_amount_missing');
      expect(await AppDatabase.instance.getTransactionsForReview(), isEmpty);
    },
  );

  test(
    'transaction-like parse with missing amount is queued for review',
    () async {
      final result = await NotificationIngestionProcessor().ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          content: 'Your account was debited at Cafe.',
        ),
      );

      expect(result.disposition, IngestionDisposition.retained);
      final reviews = await AppDatabase.instance.getTransactionsForReview();
      expect(reviews, hasLength(1));
      expect(reviews.single.parsedEvent.amountMinor, isNull);
      expect(reviews.single.rawEvent.content, contains('debited at Cafe'));
    },
  );

  test(
    'privacy cleanup preserves only text needed by pending review',
    () async {
      await NotificationIngestionProcessor().ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          content: 'Your account was debited at Cafe.',
        ),
      );
      final historicalRawId = await AppDatabase.instance
          .createRawNotificationEvent(
            RawNotificationEvent(
              packageName: 'com.example.historical',
              title: 'Old transaction',
              content: 'INR 99.00 paid at Old Store.',
              postedAt: postedAt.subtract(const Duration(days: 30)),
              ingestedAt: postedAt.subtract(const Duration(days: 30)),
              payloadHash: 'historical-payload-hash',
              parserVersion: 1,
              processingState: RawNotificationProcessingState.posted,
            ),
          );

      final redacted = await AppDatabase.instance
          .redactNonReviewRawNotificationPayloads();

      expect(redacted, 1);
      final review =
          (await AppDatabase.instance.getTransactionsForReview()).single;
      expect(review.rawEvent.content, contains('debited at Cafe'));
      final historical = await AppDatabase.instance.getRawNotificationEvent(
        historicalRawId,
      );
      expect(historical?.title, isNull);
      expect(historical?.content, isNull);
      expect(historical?.payloadHash, 'historical-payload-hash');
    },
  );

  test('dismissed review redacts text and cannot be posted', () async {
    final result = await trustedSmsProcessor().ingest(
      envelope(
        packageName: 'com.google.android.apps.messaging',
        content: 'Transaction INR 300 at Cinema completed.',
      ),
    );
    final reviews = await AppDatabase.instance.getTransactionsForReview();
    expect(reviews, hasLength(1));

    await AppDatabase.instance.dismissReviewedTransaction(
      reviews.single.parsedEvent.id!,
    );

    expect(await AppDatabase.instance.getTransactionsForReview(), isEmpty);
    final raw =
        (await AppDatabase.instance.getAllRawNotificationEvents()).single;
    expect(raw.processingState, RawNotificationProcessingState.ignored);
    expect(raw.title, isNull);
    expect(raw.content, isNull);
    expect(raw.payloadHash, isNotEmpty);
    await expectLater(
      AppDatabase.instance.resolveReviewedTransaction(
        parsedFinancialEventId: result.parsedFinancialEventId!,
        transaction: Transaction(
          amount: 300,
          type: TransactionType.debit,
          timestamp: postedAt,
          merchant: 'Cinema',
          category: 'Others',
          accountId: 1,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    expect(await AppDatabase.instance.getAccountLedgerMovements(), isEmpty);
  });

  test('reviewed refund uses refund lifecycle instead of income', () async {
    final result = await trustedSmsProcessor().ingest(
      envelope(
        packageName: 'com.google.android.apps.messaging',
        content: 'Refund INR 100.00 credited from Cafe. Ref REVIEWREFUND123.',
      ),
    );
    expect(result.disposition, IngestionDisposition.provisional);
    final review =
        (await AppDatabase.instance.getTransactionsForReview()).single;
    final accountId = await AppDatabase.instance.createAccount(
      Account(
        displayName: 'Review destination',
        accountType: AccountType.bankAccount,
      ),
    );

    await AppDatabase.instance.resolveReviewedTransaction(
      parsedFinancialEventId: review.parsedEvent.id!,
      transaction: Transaction(
        amount: 100,
        type: TransactionType.credit,
        timestamp: postedAt,
        merchant: 'Cafe',
        category: 'Food & Dining',
        accountId: accountId,
      ),
    );

    final movement =
        (await AppDatabase.instance.getAccountLedgerMovements()).single;
    expect(movement.entry.eventRole, LedgerEventRole.refund);
    expect(movement.entry.transactionGroupId, isNotNull);
    final group = await AppDatabase.instance.getTransactionGroup(
      movement.entry.transactionGroupId!,
    );
    expect(group?.completedRefundAmountMinor, 10000);
    expect(group?.netExpenseMinor, -10000);
    expect(group?.isInconsistent, isTrue);
    final summary = await AppDatabase.instance.getFinancialSummary();
    expect(summary.grossExpensesMinor, 0);
    expect(summary.completedRefundsMinor, 10000);
    expect(summary.netExpensesMinor, -10000);
    expect(summary.incomeMinor, 0);
  });

  test(
    'reviewed refund with the same reference updates its purchase group',
    () async {
      final accountId = await createHdfcAccount();
      final processor = trustedSmsProcessor();
      await processor.ingest(
        envelope(
          packageName: 'com.snapwork.hdfc',
          content:
              'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. Ref REVIEWLINK123.',
        ),
      );
      final refund = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          notificationId: 88,
          eventTime: postedAt.add(const Duration(days: 1)),
          content: 'Refund INR 100.00 credited from Cafe. Ref REVIEWLINK123.',
        ),
      );
      expect(refund.disposition, IngestionDisposition.provisional);
      final review =
          (await AppDatabase.instance.getTransactionsForReview()).single;

      await AppDatabase.instance.resolveReviewedTransaction(
        parsedFinancialEventId: review.parsedEvent.id!,
        transaction: Transaction(
          amount: 100,
          type: TransactionType.credit,
          timestamp: postedAt.add(const Duration(days: 1)),
          merchant: 'Cafe',
          category: 'Food & Dining',
          accountId: accountId,
        ),
      );

      final movements = await AppDatabase.instance.getAccountLedgerMovements();
      expect(movements, hasLength(2));
      expect(
        movements.map((movement) => movement.entry.transactionGroupId).toSet(),
        hasLength(1),
      );
      expect(movements.map((movement) => movement.entry.eventRole).toSet(), {
        LedgerEventRole.primary,
        LedgerEventRole.refund,
      });
      final group = await AppDatabase.instance.getTransactionGroup(
        movements.first.entry.transactionGroupId!,
      );
      expect(group?.groupType, TransactionGroupType.purchaseRefund);
      expect(group?.completedRefundAmountMinor, 10000);
      expect(group?.netExpenseMinor, 0);
      final summary = await AppDatabase.instance.getFinancialSummary();
      expect(summary.grossExpensesMinor, 10000);
      expect(summary.completedRefundsMinor, 10000);
      expect(summary.netExpensesMinor, 0);
      expect(summary.incomeMinor, 0);
    },
  );

  test('identical notification is not processed twice', () async {
    await createHdfcAccount();
    final processor = trustedSmsProcessor();
    final notification = envelope(
      packageName: 'com.google.android.apps.messaging',
    );

    final first = await processor.ingest(notification);
    final second = await processor.ingest(notification);

    expect(first.disposition, IngestionDisposition.posted);
    expect(second.disposition, IngestionDisposition.sourceDuplicate);
    expect(second.rawEventId, isNot(first.rawEventId));
    expect(second.duplicateConfidence, 1);
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(2),
    );
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
    expect(
      await AppDatabase.instance.getParsedEventLedgerLinks(),
      hasLength(2),
    );
  });

  test('same transaction reported by bank and UPI app shares one ledger', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    final first = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        content:
            'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR ABC123456',
      ),
    );
    final second = await processor.ingest(
      envelope(
        packageName: 'com.google.android.apps.nbu.paisa.user',
        notificationId: 20,
        content:
            'UPI payment INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR ABC123456',
      ),
    );

    expect(first.disposition, IngestionDisposition.posted);
    expect(second.disposition, IngestionDisposition.ledgerDuplicate);
    expect(second.duplicateConfidence, greaterThanOrEqualTo(.85));
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(2),
    );
    expect(
      await AppDatabase.instance.getParsedEventLedgerLinks(),
      hasLength(2),
    );
  });

  test(
    'Axis SMS and email with a comma-separated timestamp share one ledger',
    () async {
      final accountId = await AppDatabase.instance.createAccount(
        Account(
          displayName: 'Axis Savings XX8075',
          institutionId: 'axis',
          accountType: AccountType.bankAccount,
          lastFour: '8075',
        ),
      );
      final processor = NotificationIngestionProcessor(
        sourcePolicy: NotificationSourcePolicy(
          defaultSmsPackage: 'com.google.android.apps.messaging',
        ),
      );
      const sms = '''INR 96.00 debited
A/c no. XX8075
05-08-26, 21:28:31
UPI/P2A/658347613288/MAHAVEER SINGH
Not you? SMS BLOCKUPI Cust ID to 919951860002
Axis Bank''';
      const email = '''Dear Calvin Noronha,
Amount Debited: INR 96.00
Account Number: XX8075
Date & Time: 05-08-26, 21:28:31 IST
Axis Bank''';

      final first = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          notificationId: 96,
          title: 'Axis Bank',
          content: sms,
        ),
      );
      final balanceAfterPrimary = (await AppDatabase.instance.getAccount(
        accountId,
      ))!.currentBalance;
      final second = await processor.ingest(
        envelope(
          packageName: 'com.google.android.gm',
          notificationId: 97,
          title: 'Axis Bank',
          content: email,
        ),
      );

      expect(first.disposition, IngestionDisposition.posted);
      expect(second.disposition, IngestionDisposition.ledgerDuplicate);
      expect(second.duplicateConfidence, greaterThanOrEqualTo(.85));
      expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
      expect(await AppDatabase.instance.getAllAccounts(), hasLength(1));
      expect(
        (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
        balanceAfterPrimary,
      );
      expect(
        await AppDatabase.instance.getParsedEventLedgerLinks(),
        hasLength(2),
      );
      final parsed = await AppDatabase.instance.getParsedFinancialEvent(
        second.parsedFinancialEventId!,
      );
      expect(parsed?.transactionOccurredAt, DateTime(2026, 8, 5, 21, 28, 31));
    },
  );

  test('two real INR 1000 transactions within 30 seconds both post', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    final first = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        content:
            'INR 1,000.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR REALTXN001',
      ),
    );
    final second = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 11,
        eventTime: postedAt.add(const Duration(seconds: 20)),
        content:
            'INR 1,000.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR REALTXN002',
      ),
    );

    expect(first.disposition, IngestionDisposition.posted);
    expect(second.disposition, IngestionDisposition.posted);
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(2));
  });

  test('same amount and merchant on different accounts both post', () async {
    await createHdfcAccount();
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'HDFC Savings XX5678',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '5678',
        openingBalanceMinor: 100000,
      ),
    );
    final processor = NotificationIngestionProcessor();
    final first = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        content:
            'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR ACCOUNT001',
      ),
    );
    final second = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 12,
        content:
            'INR 100.00 debited from HDFC Bank A/c XX5678 at Cafe. UTR ACCOUNT002',
      ),
    );

    expect(first.disposition, IngestionDisposition.posted);
    expect(second.disposition, IngestionDisposition.posted);
    final transactions = await AppDatabase.instance.getAllTransactions();
    expect(transactions, hasLength(2));
    expect(transactions.map((transaction) => transaction.accountId).toSet(), {
      1,
      2,
    });
  });

  test('related event grouping preserves every source and parsed event', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    final purchase = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        content:
            'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR ORDER12345',
      ),
    );
    final refund = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 13,
        eventTime: postedAt.add(const Duration(days: 1)),
        content:
            'Refund INR 100.00 credited to HDFC Bank A/c XX1234 from Cafe. Ref ORDER12345',
      ),
    );
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(2),
    );
    final groupLinks = await AppDatabase.instance.getParsedEventGroupLinks();
    expect(groupLinks, hasLength(2));
    expect(
      groupLinks.map((link) => link['transaction_group_id']).toSet(),
      hasLength(1),
    );
    final group = await AppDatabase.instance.getTransactionGroup(
      groupLinks.first['transaction_group_id'] as int,
    );
    expect(group?.groupType, TransactionGroupType.purchaseRefund);
    expect(group?.originalAmountMinor, 10000);
    expect(group?.completedRefundAmountMinor, 10000);
    expect(group?.netExpenseMinor, 0);
    expect(group?.category?.toLowerCase(), isNot('salary'));
    final movements = await AppDatabase.instance.getAccountLedgerMovements();
    expect(movements, hasLength(2));
    expect(
      movements.map((movement) => movement.entry.transactionGroupId).toSet(),
      {group!.id},
    );
    expect(movements.map((movement) => movement.entry.eventRole).toSet(), {
      LedgerEventRole.primary,
      LedgerEventRole.refund,
    });
    final summary = await AppDatabase.instance.getFinancialSummary();
    expect(summary.grossExpensesMinor, 10000);
    expect(summary.completedRefundsMinor, 10000);
    expect(summary.netExpensesMinor, 0);
    expect(summary.incomeMinor, 0);
    expect(
      await AppDatabase.instance.getParsedFinancialEvent(
        purchase.parsedFinancialEventId!,
      ),
      isNotNull,
    );
    expect(
      await AppDatabase.instance.getParsedFinancialEvent(
        refund.parsedFinancialEventId!,
      ),
      isNotNull,
    );
  });

  test('refund initiated notification does not create ledger movement', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        content:
            'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. UTR REFUND1234',
      ),
    );
    final initiated = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 14,
        eventTime: postedAt.add(const Duration(hours: 1)),
        content:
            'Refund of INR 100.00 initiated to HDFC Bank A/c XX1234 from Cafe. Ref REFUND1234',
      ),
    );

    expect(initiated.disposition, IngestionDisposition.retained);
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
    final db = await AppDatabase.instance.database;
    expect(await db.query(AppDatabase.tableLedgerEntries), hasLength(1));
    expect(
      await AppDatabase.instance.getAllRawNotificationEvents(),
      hasLength(2),
    );
    expect(await AppDatabase.instance.getParsedEventGroupLinks(), hasLength(2));
    expect(await AppDatabase.instance.getTransactionsForReview(), isEmpty);
  });

  test(
    'a settled reversal posts the credit movement instead of being retained',
    () async {
      await createHdfcAccount();
      final processor = NotificationIngestionProcessor();
      await processor.ingest(
        envelope(
          packageName: 'com.snapwork.hdfc',
          content:
              'INR 700.00 debited from HDFC Bank A/c XX1234 at Cafe. Ref: TXN/290711',
        ),
      );
      final reversal = await processor.ingest(
        envelope(
          packageName: 'com.snapwork.hdfc',
          notificationId: 40,
          content:
              'INR 700.00 transaction at Cafe was reversed on card XX1234. Ref: TXN/290711',
        ),
      );

      expect(reversal.disposition, IngestionDisposition.posted);
      final transactions = await AppDatabase.instance.getAllTransactions();
      expect(transactions, hasLength(2));
      expect(transactions.map((transaction) => transaction.type).toSet(), {
        TransactionType.debit,
        TransactionType.credit,
      });
      final movements = await AppDatabase.instance.getAccountLedgerMovements();
      expect(movements.map((movement) => movement.entry.eventRole).toSet(), {
        LedgerEventRole.primary,
        LedgerEventRole.reversal,
      });
      expect(
        movements.map((movement) => movement.entry.transactionGroupId).toSet(),
        hasLength(1),
      );
      final summary = await AppDatabase.instance.getFinancialSummary();
      expect(summary.grossExpensesMinor, 0);
      expect(summary.completedRefundsMinor, 0);
      expect(summary.netExpensesMinor, 0);
      expect(summary.incomeMinor, 0);
    },
  );

  test('notification fees, cashback, and transfers use lifecycle roles', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();

    final fee = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 51,
        content:
            'INR 10.00 fee debited from HDFC Bank A/c XX1234. Ref FEE123456',
      ),
    );
    final cashback = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 52,
        eventTime: postedAt.add(const Duration(minutes: 1)),
        content:
            'INR 25.00 cashback credited to HDFC Bank A/c XX1234. Ref CASH123456',
      ),
    );
    final transfer = await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 53,
        eventTime: postedAt.add(const Duration(minutes: 2)),
        content:
            'INR 500.00 transferred and debited from HDFC Bank A/c XX1234 via NEFT. Ref TRANSFER123',
      ),
    );

    expect(fee.disposition, IngestionDisposition.posted);
    expect(cashback.disposition, IngestionDisposition.posted);
    expect(transfer.disposition, IngestionDisposition.posted);
    final movements = await AppDatabase.instance.getAccountLedgerMovements();
    expect(movements, hasLength(3));
    expect(
      movements.every((movement) => movement.entry.transactionGroupId != null),
      isTrue,
    );
    expect(
      movements.map((movement) => movement.entry.eventRole),
      containsAll([LedgerEventRole.fee, LedgerEventRole.primary]),
    );
    expect(
      movements
          .where((movement) => movement.entry.amountMinor == 50000)
          .single
          .groupType,
      TransactionGroupType.transfer,
    );

    final summary = await AppDatabase.instance.getFinancialSummary();
    expect(summary.grossExpensesMinor, 0);
    expect(summary.netExpensesMinor, 0);
    expect(summary.incomeMinor, 0);
    expect(summary.cashbackMinor, 2500);
    expect(summary.feesMinor, 1000);
    expect(summary.transfersMinor, 50000);
  });

  test('duplicate completed refund does not apply lifecycle twice', () async {
    await createHdfcAccount();
    final processor = NotificationIngestionProcessor();
    await processor.ingest(
      envelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 61,
        content:
            'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe. Ref ORDERDUP123',
      ),
    );
    final refundEnvelope = envelope(
      packageName: 'com.snapwork.hdfc',
      notificationId: 62,
      eventTime: postedAt.add(const Duration(days: 1)),
      content:
          'Refund INR 100.00 credited to HDFC Bank A/c XX1234 from Cafe. Ref ORDERDUP123',
    );
    final firstRefund = await processor.ingest(refundEnvelope);
    final duplicateRefund = await processor.ingest(refundEnvelope);

    expect(firstRefund.disposition, IngestionDisposition.posted);
    expect(duplicateRefund.disposition, IngestionDisposition.sourceDuplicate);
    expect(await AppDatabase.instance.getAllTransactions(), hasLength(2));
    final groupLinks = await AppDatabase.instance.getParsedEventGroupLinks();
    final groupIds = groupLinks
        .map((link) => link['transaction_group_id'] as int)
        .toSet();
    expect(groupIds, hasLength(1));
    final group = await AppDatabase.instance.getTransactionGroup(
      groupIds.single,
    );
    expect(group?.completedRefundAmountMinor, 10000);
    expect(group?.netExpenseMinor, 0);
    final summary = await AppDatabase.instance.getFinancialSummary();
    expect(summary.completedRefundsMinor, 10000);
    expect(summary.netExpensesMinor, 0);
  });

  for (final checkpoint in IngestionFaultCheckpoint.values) {
    test(
      'receipt transaction rolls back and retries at ${checkpoint.name}',
      () async {
        final accountId = await createHdfcAccount();
        var injected = false;
        final processor = trustedSmsProcessor(
          faultInjectorForTesting: (observed) {
            if (!injected && observed == checkpoint) {
              injected = true;
              throw StateError('injected-${checkpoint.name}');
            }
          },
        );
        final captured = envelope(
          packageName: 'com.google.android.apps.messaging',
          captureReceiptId: 'fault-receipt-${checkpoint.name}',
        );

        await expectLater(
          processor.ingest(captured),
          throwsA(isA<StateError>()),
        );
        expect(await rowCount(AppDatabase.tableRawNotificationEvents), 0);
        expect(await rowCount(AppDatabase.tableParsedFinancialEvents), 0);
        expect(await rowCount(AppDatabase.tableTransactionGroups), 0);
        expect(await rowCount(AppDatabase.tableLedgerEntries), 0);
        expect(await rowCount(AppDatabase.tableParsedEventGroupLinks), 0);
        expect(await rowCount(AppDatabase.tableParsedEventLedgerLinks), 0);
        expect(await rowCount(AppDatabase.tableTransactions), 0);
        expect(await rowCount(AppDatabase.tableNotificationTemplates), 0);
        expect(await rowCount(AppDatabase.tableParserDiagnostics), 0);
        expect(
          await rowCount(AppDatabase.tableNotificationIngestionReceipts),
          0,
        );
        expect(
          (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
          1000,
        );

        final committed = await processor.ingest(captured);
        final replay = await processor.ingest(captured);

        expect(committed.disposition, IngestionDisposition.posted);
        expect(committed.isReceiptReplay, isFalse);
        expect(replay.isReceiptReplay, isTrue);
        expect(replay.disposition, committed.disposition);
        expect(replay.rawEventId, committed.rawEventId);
        expect(replay.parsedFinancialEventId, committed.parsedFinancialEventId);
        expect(replay.transactionId, committed.transactionId);
        expect(replay.diagnosticCode, committed.diagnosticCode);
        expect(replay.duplicateConfidence, committed.duplicateConfidence);
        expect(replay.matchedLedgerEntryId, committed.matchedLedgerEntryId);
        expect(await rowCount(AppDatabase.tableRawNotificationEvents), 1);
        expect(await rowCount(AppDatabase.tableParsedFinancialEvents), 1);
        expect(await rowCount(AppDatabase.tableTransactionGroups), 1);
        expect(await rowCount(AppDatabase.tableLedgerEntries), 1);
        expect(await rowCount(AppDatabase.tableParsedEventGroupLinks), 1);
        expect(await rowCount(AppDatabase.tableParsedEventLedgerLinks), 1);
        expect(await rowCount(AppDatabase.tableTransactions), 1);
        expect(
          await rowCount(AppDatabase.tableNotificationIngestionReceipts),
          1,
        );
        expect(
          (await AppDatabase.instance.getAccount(accountId))?.currentBalance,
          900,
        );
      },
    );
  }

  test('concurrent delivery of one receipt commits exactly once', () async {
    await createHdfcAccount();
    final processor = trustedSmsProcessor();
    final captured = envelope(
      packageName: 'com.google.android.apps.messaging',
      captureReceiptId: 'concurrent-receipt',
    );

    final results = await Future.wait([
      processor.ingest(captured),
      processor.ingest(captured),
    ]);

    expect(results.where((result) => result.isReceiptReplay), hasLength(1));
    expect(results.map((result) => result.rawEventId).toSet(), hasLength(1));
    expect(
      results.map((result) => result.parsedFinancialEventId).toSet(),
      hasLength(1),
    );
    expect(results.map((result) => result.transactionId).toSet(), hasLength(1));
    expect(await rowCount(AppDatabase.tableRawNotificationEvents), 1);
    expect(await rowCount(AppDatabase.tableParsedFinancialEvents), 1);
    expect(await rowCount(AppDatabase.tableTransactionGroups), 1);
    expect(await rowCount(AppDatabase.tableLedgerEntries), 1);
    expect(await rowCount(AppDatabase.tableTransactions), 1);
  });

  test(
    'legacy null receipts remain processable without receipt rows',
    () async {
      await createHdfcAccount();
      final processor = trustedSmsProcessor();
      final captured = envelope(
        packageName: 'com.google.android.apps.messaging',
      );

      final first = await processor.ingest(captured);
      final second = await processor.ingest(captured);

      expect(first.disposition, IngestionDisposition.posted);
      expect(second.disposition, IngestionDisposition.sourceDuplicate);
      expect(first.isReceiptReplay, isFalse);
      expect(second.isReceiptReplay, isFalse);
      expect(await rowCount(AppDatabase.tableRawNotificationEvents), 2);
      expect(await rowCount(AppDatabase.tableParsedFinancialEvents), 2);
      expect(await rowCount(AppDatabase.tableTransactions), 1);
      expect(await rowCount(AppDatabase.tableNotificationIngestionReceipts), 0);
    },
  );

  test(
    'same-effect notification update links without a second effect',
    () async {
      await createHdfcAccount();
      final processor = trustedSmsProcessor();
      final first = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          captureReceiptId: 'same-effect-v1',
        ),
      );
      final second = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          captureReceiptId: 'same-effect-v2',
          title: 'Updated HDFC transaction alert',
        ),
      );

      expect(first.disposition, IngestionDisposition.posted);
      expect(second.disposition, IngestionDisposition.sourceDuplicate);
      expect(second.matchedLedgerEntryId, isNotNull);
      final rawEvents = await AppDatabase.instance
          .getAllRawNotificationEvents();
      expect(rawEvents, hasLength(2));
      expect(rawEvents.last.supersedesEventId, rawEvents.first.id);
      expect(await rowCount(AppDatabase.tableTransactions), 1);
      expect(await rowCount(AppDatabase.tableLedgerEntries), 1);
    },
  );

  test(
    'materially updated notification is retained without a second effect',
    () async {
      await createHdfcAccount();
      final processor = trustedSmsProcessor();
      final first = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          captureReceiptId: 'receipt-original-100',
        ),
      );
      final second = await processor.ingest(
        envelope(
          packageName: 'com.google.android.apps.messaging',
          captureReceiptId: 'receipt-updated-125',
          content: 'INR 125.00 debited from HDFC Bank A/c XX1234 at Cafe.',
        ),
      );

      expect(first.disposition, IngestionDisposition.posted);
      expect(second.disposition, IngestionDisposition.provisional);
      expect(second.diagnosticCode, 'updated_notification_financial_conflict');
      final rawEvents = await AppDatabase.instance
          .getAllRawNotificationEvents();
      expect(rawEvents, hasLength(2));
      expect(rawEvents.last.supersedesEventId, rawEvents.first.id);
      expect(rawEvents.last.payloadHash, isNot(rawEvents.first.payloadHash));
      expect(await AppDatabase.instance.getAllTransactions(), hasLength(1));
    },
  );

  test(
    'third update cannot bypass a retained conflicting predecessor',
    () async {
      await createHdfcAccount();
      final processor = trustedSmsProcessor();
      final results = <IngestionResult>[];
      for (final (index, amount) in <int>[100, 125, 150].indexed) {
        results.add(
          await processor.ingest(
            envelope(
              packageName: 'com.google.android.apps.messaging',
              captureReceiptId: 'supersession-chain-v${index + 1}',
              content:
                  'INR $amount.00 debited from HDFC Bank A/c XX1234 at Cafe.',
            ),
          ),
        );
      }

      expect(results.first.disposition, IngestionDisposition.posted);
      expect(results[1].disposition, IngestionDisposition.provisional);
      expect(results[2].disposition, IngestionDisposition.provisional);
      expect(
        results.skip(1).map((result) => result.diagnosticCode),
        everyElement('updated_notification_financial_conflict'),
      );
      final rawEvents = await AppDatabase.instance
          .getAllRawNotificationEvents();
      expect(rawEvents, hasLength(3));
      expect(rawEvents[1].supersedesEventId, rawEvents[0].id);
      expect(rawEvents[2].supersedesEventId, rawEvents[1].id);
      expect(await rowCount(AppDatabase.tableTransactions), 1);
      expect(await rowCount(AppDatabase.tableLedgerEntries), 1);
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
    final result = await trustedSmsProcessor().ingest(
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

class _FixtureBundledClassifier implements FinancialNotificationClassifier {
  const _FixtureBundledClassifier();

  @override
  ClassificationResult classify(NormalizedNotification notification) {
    return const ClassificationResult(
      relevance: FinancialRelevance.transaction,
      confidence: .97,
      features: {
        FinancialNotificationSemanticFeature.transactionAction,
        FinancialNotificationSemanticFeature.currencyAmount,
      },
      classifierId: 'fixture_bundled_classifier',
      classifierVersion: '1',
      kind: FinancialNotificationClassifierKind.bundledModel,
      modelVersion: 'fixture-model-v1',
    );
  }
}

class _AlwaysProvisionalValidator implements ParseValidator {
  const _AlwaysProvisionalValidator();

  @override
  ParseValidation validate({
    required FinancialRelevance relevance,
    required MonetaryCandidate? amount,
    required FinancialDirection direction,
    required FinancialEventStatus status,
    required double overallConfidence,
  }) => const ParseValidation(
    decision: ParseDecision.provisional,
    failureCode: 'forced_provisional_for_test',
  );
}
