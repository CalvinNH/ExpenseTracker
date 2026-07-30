import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/notification_template.dart';
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
  const fingerprint = '<amount> debited from <account> at <merchant>';
  const metadata = '{"version":1,"fields":[{"type":"<AMOUNT>","token":0}]}';

  Future<NotificationTemplate> observe({
    String sourcePackage = package,
    String signature = 'debit|completed|purchase|transactionAmount',
    bool successful = true,
  }) => AppDatabase.instance.observeNotificationTemplate(
    fingerprint: fingerprint,
    sourcePackage: sourcePackage,
    fieldPositionMetadata: metadata,
    roleSignature: signature,
    successfulCompletedParse: successful,
    observedAt: DateTime.utc(2026, 7, 30),
  );

  test('variable values produce the same fingerprint', () {
    final pipeline = NotificationParsingPipeline();
    const fingerprinter = NotificationStructuralFingerprinter();
    final first = fingerprinter.generate(pipeline.parse(
      'Bank alert',
      'INR 100 debited from HDFC Bank A/c XX1234 at Cafe on 26/07/2026.',
    ));
    final second = fingerprinter.generate(pipeline.parse(
      'Bank alert',
      'INR 845 debited from HDFC Bank A/c XX9876 at Store on 27/07/2026.',
    ));

    expect(first.fingerprint, second.fingerprint);
    expect(first.fingerprint, contains('<amount>'));
    expect(first.fieldPositionMetadata.toString(), isNot(contains('1234')));
  });

  test('stable template promotion requires repeated validated observations', () async {
    await observe();
    await observe();
    final promoted = await observe();

    expect(promoted.observedCount, 3);
    expect(promoted.successfulParseCount, 3);
    expect(promoted.conflictingParseCount, 0);
    expect(promoted.isPromoted, isTrue);
  });

  test('conflicting template is not promoted', () async {
    await observe();
    await observe(signature: 'credit|completed|refund|refundAmount');
    final template = await observe();

    expect(template.conflictingParseCount, greaterThan(0));
    expect(template.isPromoted, isFalse);
  });

  test('different packages do not share learned template state', () async {
    await observe();
    await observe();
    await observe();
    final otherPackage = await observe(sourcePackage: 'com.other.bank');

    expect(otherPackage.observedCount, 1);
    expect(otherPackage.isPromoted, isFalse);
  });

  test('failed notification cannot be promoted as completed spending', () async {
    await observe(successful: false);
    await observe(successful: false);
    final template = await observe(successful: false);

    expect(template.successfulParseCount, 0);
    expect(template.isPromoted, isFalse);
  });

  test('template data remains local and stores no executable rule', () async {
    final template = await observe();
    final stored = await AppDatabase.instance.getNotificationTemplate(
      fingerprint: fingerprint,
      sourcePackage: package,
    );

    expect(stored?.id, template.id);
    expect(stored?.fieldPositionMetadata, metadata);
    expect(stored?.roleSignature, isNot(contains(RegExp(r'(dart|javascript|sql|regex)', caseSensitive: false))));
  });
}
