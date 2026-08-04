import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/notification_template.dart';
import 'package:expense_tracker/features/ingestion/notification_ingestion_processor.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';
import 'package:expense_tracker/features/ingestion/structural_notification_fingerprint.dart';
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

  tearDown(() async => AppDatabase.instance.close());

  const package = 'com.example.bank';
  const fingerprint = '<AMOUNT> debited from <ACCOUNT> at <MERCHANT>';
  final metadata = NotificationTemplateFieldMetadata(
    fields: const [
      NotificationTemplateFieldPosition(
        type: NotificationTemplateFieldType.amount,
        tokenIndex: 0,
      ),
      NotificationTemplateFieldPosition(
        type: NotificationTemplateFieldType.account,
        tokenIndex: 3,
      ),
      NotificationTemplateFieldPosition(
        type: NotificationTemplateFieldType.merchant,
        tokenIndex: 5,
      ),
    ],
  );

  Future<NotificationTemplate> observe({
    String sourcePackage = package,
    String signature = 'transaction|debit|completed|purchase|transactionAmount',
    bool successful = true,
    NotificationTemplateFieldMetadata? positions,
    DateTime? observedAt,
    String templateFingerprint = fingerprint,
  }) => AppDatabase.instance.observeNotificationTemplate(
    fingerprint: templateFingerprint,
    sourcePackage: sourcePackage,
    fieldPositionMetadata: positions ?? metadata,
    roleSignature: signature,
    successfulCompletedParse: successful,
    observedAt: observedAt ?? DateTime.utc(2026, 7, 30),
  );

  test('variable values produce the same typed fingerprint', () {
    final pipeline = NotificationParsingPipeline();
    const fingerprinter = NotificationStructuralFingerprinter();
    final first = fingerprinter.generate(
      pipeline.parse(
        'Bank alert',
        'INR 100 debited from HDFC Bank A/c XX1234 at Cafe on 26/07/2026.',
      ),
    );
    final second = fingerprinter.generate(
      pipeline.parse(
        'Bank alert',
        'INR 845 debited from HDFC Bank A/c XX9876 at Store on 27/07/2026.',
      ),
    );

    expect(first.fingerprint, second.fingerprint);
    expect(first.fingerprint, contains('<AMOUNT>'));
    expect(first.fingerprint, contains('<ACCOUNT>'));
    expect(first.fingerprint, contains('<MERCHANT>'));
    expect(first.fingerprint, contains('<DATE>'));
    expect(first.fingerprint, isNot(contains('100')));
    expect(first.fieldPositionMetadata.canonicalJson, isNot(contains('1234')));
    expect(
      first.fieldPositionMetadata.canonicalJson,
      second.fieldPositionMetadata.canonicalJson,
    );
  });

  test('all supported dynamic values use typed placeholders', () {
    final parsed = NotificationParsingPipeline().parse(
      'Bank alert',
      'INR 100 debited from account XX1234 using card ending 5678 at Cafe '
          'on 26 Jul 2026 at 10:45 PM to alice@upi UTR ABC123456.',
    );
    final result = const NotificationStructuralFingerprinter().generate(parsed);

    expect(result.fingerprint, contains('<AMOUNT>'));
    expect(result.fingerprint, contains('<ACCOUNT>'));
    expect(result.fingerprint, contains('<CARD>'));
    expect(result.fingerprint, contains('<DATE>'));
    expect(result.fingerprint, contains('<TIME>'));
    expect(result.fingerprint, contains('<REFERENCE>'));
    expect(result.fingerprint, contains('<VPA>'));
    expect(result.fingerprint, contains('<MERCHANT>'));
  });

  test('overly complex untrusted input safely opts out of learning', () {
    final vpas = List.generate(17, (index) => 'person$index@upi').join(' ');
    final parsed = NotificationParsingPipeline().parse(
      'Bank alert',
      'INR 100 debited $vpas',
    );
    final result = const NotificationStructuralFingerprinter().generate(parsed);

    expect(result.canBeLearned, isFalse);
    expect(result.fieldPositionMetadata.fields, isEmpty);
  });

  test(
    'stable template promotion requires repeated validated observations',
    () async {
      final first = await observe(observedAt: DateTime.utc(2026, 7, 30, 8));
      final second = await observe(observedAt: DateTime.utc(2026, 7, 30, 9));
      final promoted = await observe(observedAt: DateTime.utc(2026, 7, 30, 10));

      expect(
        first.promotionStatus,
        NotificationTemplatePromotionStatus.learning,
      );
      expect(
        second.promotionStatus,
        NotificationTemplatePromotionStatus.learning,
      );
      expect(promoted.observedCount, 3);
      expect(promoted.successfulParseCount, 3);
      expect(promoted.conflictingParseCount, 0);
      expect(
        promoted.promotionStatus,
        NotificationTemplatePromotionStatus.promoted,
      );
    },
  );

  test('validated ingestion promotes a stable package-local shape', () async {
    await AppDatabase.instance.createAccount(
      Account(
        displayName: 'HDFC Savings XX1234',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '1234',
        openingBalanceMinor: 100000,
      ),
    );
    final processor = NotificationIngestionProcessor();
    StructuralNotificationFingerprint? firstShape;
    for (var i = 1; i <= 3; i++) {
      final content =
          'INR ${i * 101}.00 debited from HDFC Bank A/c XX1234 at Shop$i '
          'on 0$i/08/2026.';
      final parsed = NotificationParsingPipeline().parse(
        'Transaction alert',
        content,
        sourcePackage: 'com.snapwork.hdfc',
        knownPackage: true,
      );
      expect(parsed.decision, ParseDecision.autoPost);
      final shape = const NotificationStructuralFingerprinter().generate(
        parsed,
      );
      firstShape ??= shape;
      expect(shape.fingerprint, firstShape.fingerprint);
      await processor.ingest(
        NotificationEnvelope(
          packageName: 'com.snapwork.hdfc',
          notificationId: i,
          title: 'Transaction alert',
          content: content,
          postedAt: DateTime.utc(2026, 8, i, 10),
          ingestedAt: DateTime.utc(2026, 8, i, 10, 0, 1),
        ),
      );
    }

    final template = await AppDatabase.instance.getNotificationTemplate(
      fingerprint: firstShape!.fingerprint,
      sourcePackage: 'com.snapwork.hdfc',
    );
    expect(template?.observedCount, 3);
    expect(template?.successfulParseCount, 3);
    expect(template?.isPromoted, isTrue);
  });

  test(
    'conflicting field roles block and demote a template permanently',
    () async {
      await observe();
      await observe();
      final previouslyPromoted = await observe();
      expect(previouslyPromoted.isPromoted, isTrue);

      final blocked = await observe(
        signature: 'transaction|credit|completed|refund|refundAmount',
      );
      final stillBlocked = await observe();

      expect(blocked.conflictingParseCount, 1);
      expect(blocked.successfulParseCount, 3);
      expect(
        blocked.promotionStatus,
        NotificationTemplatePromotionStatus.blocked,
      );
      expect(
        stillBlocked.promotionStatus,
        NotificationTemplatePromotionStatus.blocked,
      );
      expect(stillBlocked.isPromoted, isFalse);
      expect(stillBlocked.roleSignature, previouslyPromoted.roleSignature);
      expect(
        stillBlocked.fieldPositionMetadata.canonicalJson,
        previouslyPromoted.fieldPositionMetadata.canonicalJson,
      );
    },
  );

  test('different packages do not share learned template state', () async {
    await observe(sourcePackage: package);
    await observe(sourcePackage: package);
    final promoted = await observe(sourcePackage: package);
    final otherPackage = await observe(sourcePackage: 'com.other.bank');
    final caseDistinctPackage = await observe(
      sourcePackage: 'COM.EXAMPLE.BANK',
    );

    expect(promoted.isPromoted, isTrue);
    expect(promoted.sourcePackage, package);
    expect(otherPackage.observedCount, 1);
    expect(otherPackage.isPromoted, isFalse);
    expect(caseDistinctPackage.observedCount, 1);
    expect(caseDistinctPackage.isPromoted, isFalse);
  });

  test(
    'failed notification cannot be promoted as completed spending',
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
      expect(accountId, greaterThan(0));
      final processor = NotificationIngestionProcessor();
      StructuralNotificationFingerprint? shape;

      for (var i = 1; i <= 3; i++) {
        final content =
            'INR ${i * 100}.00 debited from HDFC Bank A/c XX1234 at Cafe '
            'on 0$i/08/2026 failed.';
        final parsed = NotificationParsingPipeline().parse(
          'Transaction alert',
          content,
          sourcePackage: 'com.snapwork.hdfc',
          knownPackage: true,
        );
        expect(parsed.status, FinancialEventStatus.failed);
        shape ??= const NotificationStructuralFingerprinter().generate(parsed);
        expect(
          (await processor.ingest(
            NotificationEnvelope(
              packageName: 'com.snapwork.hdfc',
              notificationId: i,
              title: 'Transaction alert',
              content: content,
              postedAt: DateTime.utc(2026, 8, i, 10),
              ingestedAt: DateTime.utc(2026, 8, i, 10, 0, 1),
            ),
          )).disposition,
          IngestionDisposition.retained,
        );
      }

      final template = await AppDatabase.instance.getNotificationTemplate(
        fingerprint: shape!.fingerprint,
        sourcePackage: 'com.snapwork.hdfc',
      );
      expect(template, isNotNull);
      expect(template!.observedCount, 3);
      expect(template.successfulParseCount, 0);
      expect(template.isPromoted, isFalse);
      expect(await AppDatabase.instance.getAllTransactions(), isEmpty);
    },
  );

  test(
    'failed, pending, and initiated states are never promotable evidence',
    () async {
      for (final status in ['failed', 'pending', 'initiated']) {
        final statusFingerprint = '<AMOUNT> transfer $status';
        for (var i = 0; i < 3; i++) {
          await observe(
            templateFingerprint: statusFingerprint,
            positions: NotificationTemplateFieldMetadata(
              fields: const [
                NotificationTemplateFieldPosition(
                  type: NotificationTemplateFieldType.amount,
                  tokenIndex: 0,
                ),
              ],
            ),
            signature: 'transaction|debit|$status|transfer|transactionAmount',
            successful: false,
          );
        }
        final template = await AppDatabase.instance.getNotificationTemplate(
          fingerprint: statusFingerprint,
          sourcePackage: package,
        );
        expect(template?.successfulParseCount, 0, reason: status);
        expect(template?.isPromoted, isFalse, reason: status);
      }
    },
  );

  test(
    'exact duplicate payloads cannot satisfy repetition threshold',
    () async {
      await AppDatabase.instance.createAccount(
        Account(
          displayName: 'HDFC Savings XX1234',
          institutionId: 'hdfc',
          accountType: AccountType.bankAccount,
          lastFour: '1234',
          openingBalanceMinor: 100000,
        ),
      );
      final processor = NotificationIngestionProcessor();
      final notification = NotificationEnvelope(
        packageName: 'com.snapwork.hdfc',
        notificationId: 42,
        title: 'Transaction alert',
        content: 'INR 100.00 debited from HDFC Bank A/c XX1234 at Cafe.',
        postedAt: DateTime.utc(2026, 8, 1, 10),
        ingestedAt: DateTime.utc(2026, 8, 1, 10, 0, 1),
      );
      await processor.ingest(notification);
      await processor.ingest(notification);
      await processor.ingest(notification);

      final parsed = NotificationParsingPipeline().parse(
        notification.title!,
        notification.content!,
        sourcePackage: notification.packageName,
        knownPackage: true,
      );
      final shape = const NotificationStructuralFingerprinter().generate(
        parsed,
      );
      final template = await AppDatabase.instance.getNotificationTemplate(
        fingerprint: shape.fingerprint,
        sourcePackage: notification.packageName,
      );
      expect(template?.observedCount, 1);
      expect(template?.isPromoted, isFalse);
    },
  );

  test(
    'template metadata is strict local data and never executable code',
    () async {
      expect(
        () => NotificationTemplateFieldMetadata.fromJsonString(
          '{"version":1,"fields":[{"type":"<REGEX>","token":0}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => NotificationTemplateFieldMetadata.fromJsonString(
          '{"version":1,"fields":[{"type":"<AMOUNT>","token":0,'
          '"regex":".*"}]}',
        ),
        throwsFormatException,
      );

      const inertFingerprint =
          "<AMOUNT> spent at merchant'; DROP TABLE accounts; --";
      final template = await observe(
        templateFingerprint: inertFingerprint,
        positions: NotificationTemplateFieldMetadata(
          fields: const [
            NotificationTemplateFieldPosition(
              type: NotificationTemplateFieldType.amount,
              tokenIndex: 0,
            ),
          ],
        ),
      );
      final stored = await AppDatabase.instance.getNotificationTemplate(
        fingerprint: inertFingerprint,
        sourcePackage: package,
      );
      final db = await AppDatabase.instance.database;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [AppDatabase.tableNotificationTemplates],
      );

      expect(stored?.id, template.id);
      expect(
        stored?.fieldPositionMetadata.canonicalJson,
        isNot(contains('regex')),
      );
      expect(tables, hasLength(1));
    },
  );
}
