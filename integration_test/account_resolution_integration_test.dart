import 'dart:io';

import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/entity_resolution/account_resolver.dart';
import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/ledger_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late InstitutionRegistry registry;
  late AccountResolver resolver;
  late Directory databaseDirectory;

  setUpAll(() async {
    registry = await InstitutionRegistry.load();
    resolver = AccountResolver(registry);
  });

  setUp(() async {
    await AppDatabase.instance.close();
    databaseDirectory = await Directory.systemTemp.createTemp(
      'account_resolution_integration_',
    );
    AppDatabase.databasePathOverrideForTesting =
        '${databaseDirectory.path}${Platform.pathSeparator}test.db';
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.databasePathOverrideForTesting = null;
    if (databaseDirectory.existsSync()) {
      databaseDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets('transactions resolve only to the correct account', (
    tester,
  ) async {
    final accounts = [
      Account(
        id: 1,
        displayName: 'SBI primary',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
        lastFour: '1111',
      ),
      Account(
        id: 2,
        displayName: 'SBI salary',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
        lastFour: '2222',
      ),
      Account(
        id: 3,
        displayName: 'HDFC savings',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '3333',
      ),
    ];

    final sameBank = resolver.resolve(
      accounts,
      const AccountResolutionEvidence(
        institution: 'State Bank',
        instrumentLastFour: '2222',
      ),
    );
    expect(sameBank.resolvedAccountId, 2);
    expect(sameBank.candidateAccountIds, isNot(contains(1)));
    expect(sameBank.candidateAccountIds, isNot(contains(3)));

    final differentBank = resolver.resolve(
      accounts,
      const AccountResolutionEvidence(
        institution: 'HDFC',
        instrumentLastFour: '3333',
      ),
    );
    expect(differentBank.resolvedAccountId, 3);
    expect(differentBank.candidateAccountIds, isNot(contains(1)));
    expect(differentBank.candidateAccountIds, isNot(contains(2)));

    final conflict = resolver.resolve(
      accounts,
      const AccountResolutionEvidence(
        institution: 'SBI',
        instrumentLastFour: '3333',
      ),
    );
    expect(conflict.resolvedAccountId, isNull);
    expect(conflict.resolutionStatus, ResolutionStatus.newInstrumentCandidate);
    expect(conflict.candidateAccountIds, isEmpty);
  });

  testWidgets('aliases and accounts without last four resolve safely', (
    tester,
  ) async {
    final accounts = [
      Account(
        id: 10,
        displayName: 'SBI account',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
      ),
      Account(
        id: 20,
        displayName: 'HDFC account',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
      ),
    ];

    for (final alias in ['SBI', 'State Bank', 'State Bank of India']) {
      final result = resolver.resolve(
        accounts,
        AccountResolutionEvidence(institution: alias),
      );
      expect(result.resolvedAccountId, 10, reason: 'alias: $alias');
      expect(result.candidateAccountIds, isNot(contains(20)));
    }
  });

  testWidgets('an unknown wallet is never assigned to an account', (
    tester,
  ) async {
    final result = resolver.resolve(
      [
        Account(
          id: 1,
          displayName: 'SBI account',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
        ),
      ],
      const AccountResolutionEvidence(
        rawText: 'INR 50 paid using an unknown wallet',
      ),
    );

    expect(result.resolvedAccountId, isNull);
    expect(result.resolutionStatus, ResolutionStatus.unresolved);
    expect(result.candidateAccountIds, isEmpty);
  });

  testWidgets('a provisional account merges into the confirmed account', (
    tester,
  ) async {
    final confirmedId = await AppDatabase.instance.createAccount(
      Account(
        displayName: 'SBI confirmed',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
        openingBalanceMinor: 10000,
      ),
    );
    final provisionalId = await AppDatabase.instance.createAccount(
      Account(
        displayName: 'SBI account ending 3482',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
        lastFour: '3482',
        isProvisional: true,
        openingBalanceMinor: 2000,
      ),
    );
    await AppDatabase.instance.createLedgerEntry(
      LedgerEntry(
        accountId: provisionalId,
        direction: FinancialDirection.credit,
        amountMinor: 500,
        currencyCode: 'INR',
        occurredAt: DateTime.utc(2026, 7, 1),
        eventRole: LedgerEventRole.primary,
        createdAt: DateTime.utc(2026, 7, 1),
      ),
    );

    await AppDatabase.instance.mergeProvisionalAccount(
      provisionalAccountId: provisionalId,
      confirmedAccountId: confirmedId,
    );

    expect(await AppDatabase.instance.getAccount(provisionalId), isNull);
    final confirmed = await AppDatabase.instance.getAccount(confirmedId);
    expect(confirmed?.openingBalanceMinor, 12000);
    expect(confirmed?.currentBalance, 125);

    final db = await AppDatabase.instance.database;
    final mergedLedger = await db.query(
      AppDatabase.tableLedgerEntries,
      where: 'account_id = ?',
      whereArgs: [confirmedId],
    );
    expect(mergedLedger, hasLength(1));
    expect(mergedLedger.single['account_id'], confirmedId);
    expect(await db.query(AppDatabase.tableAccountMerges), hasLength(1));
  });
}
