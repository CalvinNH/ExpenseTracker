import 'package:expense_tracker/core/entity_resolution/account_resolver.dart';
import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InstitutionRegistry registry;
  late AccountResolver resolver;

  setUpAll(() async {
    registry = await InstitutionRegistry.load();
    resolver = AccountResolver(registry);
  });

  test('State Bank, SBI and State Bank of India are canonical aliases', () {
    expect(registry.byId('State Bank')?.institutionId, 'sbi');
    expect(registry.byId('SBI')?.institutionId, 'sbi');
    expect(registry.byId('State Bank of India')?.institutionId, 'sbi');
  });

  test('same-bank accounts are distinguished by suffix', () {
    final result = resolver.resolve(
      [
        Account(
          id: 1,
          displayName: 'Home',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          lastFour: '1111',
        ),
        Account(
          id: 2,
          displayName: 'Salary',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          lastFour: '3482',
        ),
      ],
      const AccountResolutionEvidence(
        institution: 'State Bank',
        instrumentLastFour: '3482',
      ),
    );
    expect(result.resolvedAccountId, 2);
    expect(result.resolutionStatus, ResolutionStatus.exact);
  });

  test('different-bank accounts are isolated by institution and suffix', () {
    final result = resolver.resolve(
      [
        Account(
          id: 1,
          displayName: 'SBI savings',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          lastFour: '1111',
        ),
        Account(
          id: 2,
          displayName: 'HDFC savings',
          institutionId: 'hdfc',
          accountType: AccountType.bankAccount,
          lastFour: '2222',
        ),
      ],
      const AccountResolutionEvidence(
        institution: 'State Bank of India',
        instrumentLastFour: '1111',
      ),
    );
    expect(result.resolvedAccountId, 1);
    expect(result.candidateAccountIds, isNot(contains(2)));
  });

  test('single matching-bank account without suffix is selected safely', () {
    final result = resolver.resolve([
      Account(
        id: 1,
        displayName: 'SBI savings',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
      ),
      Account(
        id: 2,
        displayName: 'HDFC savings',
        institutionId: 'hdfc',
        accountType: AccountType.bankAccount,
        lastFour: '2222',
      ),
    ], const AccountResolutionEvidence(institution: 'SBI'));
    expect(result.resolvedAccountId, 1);
    expect(result.resolutionStatus, ResolutionStatus.probable);
    expect(result.candidateAccountIds, isNot(contains(2)));
  });

  test('conflicting bank and suffix never select the wrong-bank account', () {
    final result = resolver.resolve(
      [
        Account(
          id: 1,
          displayName: 'SBI savings',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          lastFour: '1111',
        ),
        Account(
          id: 2,
          displayName: 'HDFC savings',
          institutionId: 'hdfc',
          accountType: AccountType.bankAccount,
          lastFour: '2222',
        ),
      ],
      const AccountResolutionEvidence(
        institution: 'SBI',
        instrumentLastFour: '2222',
      ),
    );
    expect(result.resolvedAccountId, isNull);
    expect(result.resolutionStatus, ResolutionStatus.newInstrumentCandidate);
    expect(result.candidateAccountIds, isEmpty);
  });

  test('ambiguous same-bank accounts are not auto-selected', () {
    final result = resolver.resolve([
      Account(
        id: 1,
        displayName: 'Home',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
      ),
      Account(
        id: 2,
        displayName: 'Salary',
        institutionId: 'sbi',
        accountType: AccountType.bankAccount,
      ),
    ], const AccountResolutionEvidence(institution: 'SBI'));
    expect(result.resolvedAccountId, isNull);
    expect(result.resolutionStatus, ResolutionStatus.ambiguous);
    expect(result.candidateAccountIds, containsAll([1, 2]));
  });

  test('package and institution support resolution', () {
    final result = resolver.resolve(
      [
        Account(
          id: 4,
          displayName: 'Main',
          institutionId: 'sbi',
          accountType: AccountType.bankAccount,
          sourcePackageHint: 'com.sbi.lotusintouch',
        ),
      ],
      const AccountResolutionEvidence(
        institution: 'State Bank of India',
        sourcePackage: 'com.sbi.lotusintouch',
      ),
    );
    expect(result.resolvedAccountId, 4);
  });

  test('payment application package does not identify a bank account', () {
    final result = resolver.resolve(
      [
        Account(
          id: 1,
          displayName: 'Main bank',
          institutionId: 'google_pay',
          accountType: AccountType.bankAccount,
        ),
      ],
      const AccountResolutionEvidence(
        institution: 'Google Pay',
        sourcePackage: 'com.google.android.apps.nbu.paisa.user',
      ),
    );
    expect(result.resolvedAccountId, isNull);
  });

  test('there is no first-account fallback', () {
    final result = resolver.resolve([
      Account(id: 1, displayName: 'Cash', accountType: AccountType.cash),
    ], const AccountResolutionEvidence(rawText: 'Unknown purchase'));
    expect(result.resolvedAccountId, isNull);
    expect(result.resolutionStatus, ResolutionStatus.unresolved);
  });

  test(
    'known wallet is a new instrument candidate but generic wallet is not',
    () {
      final known = resolver.resolve(
        const [],
        const AccountResolutionEvidence(
          rawText: 'INR 50 paid using Amazon Pay Wallet',
        ),
      );
      final generic = resolver.resolve(
        const [],
        const AccountResolutionEvidence(
          rawText: 'INR 50 paid using an unknown wallet',
        ),
      );
      expect(known.resolutionStatus, ResolutionStatus.newInstrumentCandidate);
      expect(generic.resolutionStatus, ResolutionStatus.unresolved);
    },
  );
}
