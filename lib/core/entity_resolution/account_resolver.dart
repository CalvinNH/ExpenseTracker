import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';

enum ResolutionStatus {
  exact,
  probable,
  ambiguous,
  unresolved,
  newInstrumentCandidate,
}

enum MatchedEvidence {
  suffixAndInstitution,
  exactSuffix,
  upiHandle,
  sourcePackageAndInstitution,
  canonicalInstitutionAlias,
  fuzzyAlias,
}

class AccountResolutionResult {
  const AccountResolutionResult({
    required this.resolvedAccountId,
    required this.resolutionStatus,
    required this.confidence,
    required this.matchedEvidence,
    required this.candidateAccountIds,
  });

  final int? resolvedAccountId;
  final ResolutionStatus resolutionStatus;
  final double confidence;
  final List<MatchedEvidence> matchedEvidence;
  final List<int> candidateAccountIds;
}

class AccountResolutionEvidence {
  const AccountResolutionEvidence({
    this.institution,
    this.instrumentLastFour,
    this.upiHandle,
    this.sourcePackage,
    this.rawText = '',
  });

  final String? institution;
  final String? instrumentLastFour;
  final String? upiHandle;
  final String? sourcePackage;
  final String rawText;
}

class AccountResolver {
  const AccountResolver(this.registry);
  final InstitutionRegistry registry;

  AccountResolutionResult resolve(
    List<Account> accounts,
    AccountResolutionEvidence evidence,
  ) {
    final suffix = evidence.instrumentLastFour;
    final institution = registry.byId(evidence.institution);
    final compatibleInstitutionAccounts = institution == null
        ? <Account>[]
        : accounts
              .where((account) => _institutionMatches(account, institution))
              .toList();

    if (suffix != null) {
      final suffixMatches = accounts
          .where((a) => a.lastFour == suffix)
          .toList();
      final both = suffixMatches
          .where(
            (a) => institution != null && _institutionMatches(a, institution),
          )
          .toList();
      if (both.length == 1) {
        return _resolved(both.single, 1, MatchedEvidence.suffixAndInstitution);
      }
      if (both.length > 1) {
        return _ambiguous(both, 1, MatchedEvidence.suffixAndInstitution);
      }
      if (suffixMatches.length == 1) {
        return _resolved(
          suffixMatches.single,
          .96,
          MatchedEvidence.exactSuffix,
        );
      }
      if (suffixMatches.length > 1) {
        return _ambiguous(suffixMatches, .96, MatchedEvidence.exactSuffix);
      }
    }

    final upi = _normalizeUpi(
      evidence.upiHandle ?? _extractUpi(evidence.rawText),
    );
    if (upi != null) {
      final matches = accounts
          .where((a) => _normalizeUpi(a.upiHandle) == upi)
          .toList();
      if (matches.length == 1) {
        return _resolved(matches.single, .94, MatchedEvidence.upiHandle);
      }
      if (matches.length > 1) {
        return _ambiguous(matches, .94, MatchedEvidence.upiHandle);
      }
    }

    if (evidence.sourcePackage != null && institution != null) {
      final packageRecords = registry.byPackage(evidence.sourcePackage!);
      final packageCompatible = compatibleInstitutionAccounts.where((account) {
        if (account.sourcePackageHint == evidence.sourcePackage) return true;
        return packageRecords.any(
          (record) => _institutionMatches(account, record),
        );
      }).toList();
      if (packageCompatible.length == 1) {
        return _resolved(
          packageCompatible.single,
          .88,
          MatchedEvidence.sourcePackageAndInstitution,
        );
      }
      if (packageCompatible.length > 1) {
        return _ambiguous(
          packageCompatible,
          .88,
          MatchedEvidence.sourcePackageAndInstitution,
        );
      }
    }
    if (evidence.sourcePackage != null) {
      final packageRecords = registry.byPackage(evidence.sourcePackage!);
      final packageMatches = accounts.where((account) {
        if (account.sourcePackageHint != evidence.sourcePackage) return false;
        return packageRecords.any(
          (record) => isAccountTypeCompatible(
            account.accountType,
            record.institutionType,
          ),
        );
      }).toList();
      if (packageMatches.length == 1) {
        return _resolved(
          packageMatches.single,
          .86,
          MatchedEvidence.sourcePackageAndInstitution,
          ResolutionStatus.probable,
        );
      }
      if (packageMatches.length > 1) {
        return _ambiguous(
          packageMatches,
          .86,
          MatchedEvidence.sourcePackageAndInstitution,
        );
      }
    }

    if (institution != null) {
      if (compatibleInstitutionAccounts.length == 1) {
        return _resolved(
          compatibleInstitutionAccounts.single,
          .8,
          MatchedEvidence.canonicalInstitutionAlias,
          ResolutionStatus.probable,
        );
      }
      if (compatibleInstitutionAccounts.length > 1) {
        return _ambiguous(
          compatibleInstitutionAccounts,
          .8,
          MatchedEvidence.canonicalInstitutionAlias,
        );
      }
    }

    var fuzzyInstitutions = registry.institutions
        .where((record) => _containsAlias(evidence.rawText, record))
        .toList();
    if (fuzzyInstitutions.length > 1) {
      final scores = {
        for (final record in fuzzyInstitutions)
          record: _longestMatchingAlias(evidence.rawText, record),
      };
      final best = scores.values.reduce((a, b) => a > b ? a : b);
      fuzzyInstitutions = fuzzyInstitutions
          .where((record) => scores[record] == best)
          .toList();
    }
    if (fuzzyInstitutions.length == 1) {
      final fuzzyInstitution = fuzzyInstitutions.single;
      final matches = accounts
          .where((a) => _institutionMatches(a, fuzzyInstitution))
          .toList();
      if (matches.length == 1) {
        return _resolved(
          matches.single,
          .68,
          MatchedEvidence.fuzzyAlias,
          ResolutionStatus.probable,
        );
      }
      if (matches.length > 1) {
        return _ambiguous(matches, .68, MatchedEvidence.fuzzyAlias);
      }
      if (fuzzyInstitution.institutionType == InstitutionType.wallet) {
        return const AccountResolutionResult(
          resolvedAccountId: null,
          resolutionStatus: ResolutionStatus.newInstrumentCandidate,
          confidence: .82,
          matchedEvidence: [MatchedEvidence.fuzzyAlias],
          candidateAccountIds: [],
        );
      }
    }

    if (suffix != null && institution != null) {
      return const AccountResolutionResult(
        resolvedAccountId: null,
        resolutionStatus: ResolutionStatus.newInstrumentCandidate,
        confidence: .9,
        matchedEvidence: [MatchedEvidence.suffixAndInstitution],
        candidateAccountIds: [],
      );
    }
    return const AccountResolutionResult(
      resolvedAccountId: null,
      resolutionStatus: ResolutionStatus.unresolved,
      confidence: 0,
      matchedEvidence: [],
      candidateAccountIds: [],
    );
  }

  bool _institutionMatches(Account account, InstitutionRecord record) {
    if (!isAccountTypeCompatible(account.accountType, record.institutionType)) {
      return false;
    }
    if (account.institutionId != null) {
      return registry.byId(account.institutionId)?.institutionId ==
          record.institutionId;
    }
    // Legacy compatibility is exact normalized equality, never substring.
    final name = InstitutionRegistry.normalize(account.displayName);
    return InstitutionRegistry.normalize(record.canonicalName) == name ||
        record.aliases.any(
          (alias) => InstitutionRegistry.normalize(alias) == name,
        );
  }

  bool _containsAlias(String text, InstitutionRecord record) {
    final lower = text.toLowerCase();
    return [record.canonicalName, ...record.aliases].any((alias) {
      final escaped = RegExp.escape(alias.toLowerCase());
      return RegExp('(?:^|[^a-z0-9])$escaped(?:[^a-z0-9]|\$)').hasMatch(lower);
    });
  }

  int _longestMatchingAlias(String text, InstitutionRecord record) {
    final lower = text.toLowerCase();
    return [record.canonicalName, ...record.aliases]
        .where((alias) => lower.contains(alias.toLowerCase()))
        .fold(
          0,
          (length, alias) => alias.length > length ? alias.length : length,
        );
  }

  AccountResolutionResult _resolved(
    Account account,
    double confidence,
    MatchedEvidence evidence, [
    ResolutionStatus status = ResolutionStatus.exact,
  ]) => AccountResolutionResult(
    resolvedAccountId: account.id,
    resolutionStatus: status,
    confidence: confidence,
    matchedEvidence: [evidence],
    candidateAccountIds: [if (account.id != null) account.id!],
  );

  AccountResolutionResult _ambiguous(
    List<Account> accounts,
    double confidence,
    MatchedEvidence evidence,
  ) => AccountResolutionResult(
    resolvedAccountId: null,
    resolutionStatus: ResolutionStatus.ambiguous,
    confidence: confidence,
    matchedEvidence: [evidence],
    candidateAccountIds: accounts.map((a) => a.id).whereType<int>().toList(),
  );

  String? _extractUpi(String text) => RegExp(
    r'\b[a-z0-9._-]{2,}@[a-z][a-z0-9.-]{1,}\b',
    caseSensitive: false,
  ).firstMatch(text)?.group(0);

  String? _normalizeUpi(String? value) => value?.trim().toLowerCase();
}

bool isAccountTypeCompatible(
  AccountType accountType,
  InstitutionType institutionType,
) => switch (institutionType) {
  InstitutionType.financialInstitution =>
    accountType == AccountType.bankAccount ||
        accountType == AccountType.creditCard ||
        accountType == AccountType.debitCard ||
        accountType == AccountType.unknown,
  InstitutionType.paymentApplication =>
    accountType == AccountType.wallet || accountType == AccountType.unknown,
  InstitutionType.wallet =>
    accountType == AccountType.wallet || accountType == AccountType.unknown,
  InstitutionType.merchantPlatform => false,
};
