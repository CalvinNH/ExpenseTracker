import 'dart:convert';
import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/parser_diagnostic.dart';
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
  });

  tearDown(() => AppDatabase.instance.close());

  test('ingestion records value-free local parser diagnostics', () async {
    const rawAmount = '₹1,234.56';
    const rawAccount = '9988';
    const rawReference = 'ABC123456789';
    const rawVpa = 'private.user@bank';
    const rawMerchant = 'Secret Medical Store';

    await NotificationIngestionProcessor().ingest(
      NotificationEnvelope(
        packageName: 'com.google.android.apps.messaging',
        title: 'Transaction alert',
        content:
            '$rawAmount debited from account XX$rawAccount at $rawMerchant '
            'via $rawVpa Ref $rawReference',
        ingestedAt: DateTime.utc(2026, 8, 2),
      ),
    );

    final rows = await AppDatabase.instance.getParserDiagnostics();
    expect(rows, hasLength(1));
    final diagnostic = rows.single;
    expect(diagnostic.parserVersion, greaterThan(0));
    expect(diagnostic.extractorsUsed, contains('validator.default.v1'));
    expect(diagnostic.extractorsUsed, contains(startsWith('classifier.')));
    expect(diagnostic.decision, isNotEmpty);
    expect(diagnostic.confidence, inInclusiveRange(0, 1));
    expect(diagnostic.sourceCategory, 'defaultSmsPackage');
    expect(diagnostic.structuralFingerprint, contains('<AMOUNT>'));

    final exported = jsonEncode(diagnostic.toExportMap());
    for (final secret in <String>[
      rawAmount,
      rawAccount,
      rawReference,
      rawVpa,
      rawMerchant,
    ]) {
      expect(exported.toLowerCase(), isNot(contains(secret.toLowerCase())));
    }
  });

  test('redactor removes sensitive values from defensive fallback shapes', () {
    const raw =
        'rs 930.25 debited from account xx4455 at Private Clinic on today '
        'vpa patient@upi ref ZXCV123456';
    final redacted = ParserDiagnosticRedactor.redactFingerprint(raw);

    expect(redacted, contains('<AMOUNT>'));
    expect(redacted, contains('<ACCOUNT>'));
    expect(redacted, contains('<VPA>'));
    expect(redacted, contains('<REFERENCE>'));
    expect(redacted, contains('<MERCHANT>'));
    expect(redacted, isNot(contains('930.25')));
    expect(redacted, isNot(contains('4455')));
    expect(redacted, isNot(contains('patient@upi')));
    expect(redacted, isNot(contains('ZXCV123456')));
    expect(redacted, isNot(contains('Private Clinic')));
  });

  test('diagnostics export exists only behind an explicit settings action', () {
    final settings = File(
      'lib/features/settings/presentation/settings_screen.dart',
    ).readAsStringSync();
    expect(settings, contains("'Export Parser Diagnostics'"));
    expect(settings, contains('onTap: _exportParserDiagnostics'));
    expect(settings, contains('diagnostic.toExportMap()'));
    expect(settings, contains('if (await file.exists()) await file.delete()'));
  });

  test('release logger has an unconditional privacy gate before file IO', () {
    final logger = File(
      'lib/core/services/notification_log_service.dart',
    ).readAsStringSync();
    expect(logger, contains('if (kReleaseMode) return;'));
    expect(logger, isNot(contains('parsedSummary')));
    expect(logger, isNot(contains('accountName')));
  });
}
