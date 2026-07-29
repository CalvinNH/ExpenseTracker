enum MatchRationale {
  notificationIdentity,
  payloadHash,
  transactionReference,
  refundOrOrderReference,
  exactAccountAndAmount,
  merchantAndAmount,
  compatibleEventSequence,
  timeProximity,
  sourcePackageRelationship,
}

extension MatchRationaleStorage on MatchRationale {
  String get storageValue => name;
}

class DuplicateAssessment {
  const DuplicateAssessment({
    required this.confidence,
    required this.rationales,
    this.matchedId,
    this.ambiguous = false,
  });

  const DuplicateAssessment.none()
    : confidence = 0,
      rationales = const [],
      matchedId = null,
      ambiguous = false;

  final double confidence;
  final List<MatchRationale> rationales;
  final int? matchedId;
  final bool ambiguous;

  bool get isDefinitive => matchedId != null && !ambiguous && confidence >= .85;
}

class FinancialEventFingerprint {
  const FinancialEventFingerprint({
    required this.amountMinor,
    required this.currencyCode,
    required this.direction,
    required this.accountId,
    this.merchant,
    this.reference,
    this.paymentRail,
    required this.occurredAt,
    required this.sourcePackage,
  });

  final int amountMinor;
  final String currencyCode;
  final String direction;
  final int accountId;
  final String? merchant;
  final String? reference;
  final String? paymentRail;
  final DateTime occurredAt;
  final String sourcePackage;

  String get canonical {
    String normalize(String? value) =>
        value?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    final timeBucket = occurredAt.toUtc().millisecondsSinceEpoch ~/ 300000;
    return [
      amountMinor,
      normalize(currencyCode),
      normalize(direction),
      accountId,
      normalize(merchant),
      normalize(reference),
      normalize(paymentRail),
      timeBucket,
      normalize(sourcePackage),
    ].join('|');
  }
}

class LedgerMatchCandidate {
  const LedgerMatchCandidate({
    required this.ledgerEntryId,
    required this.fingerprint,
  });

  final int ledgerEntryId;
  final FinancialEventFingerprint fingerprint;
}

class LedgerDuplicateDetector {
  const LedgerDuplicateDetector();

  DuplicateAssessment assess(
    FinancialEventFingerprint incoming,
    List<LedgerMatchCandidate> candidates,
  ) {
    final ranked =
        candidates
            .map((candidate) => _score(incoming, candidate))
            .where((assessment) => assessment.confidence > 0)
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (ranked.isEmpty) return const DuplicateAssessment.none();

    final best = ranked.first;
    final tied =
        ranked.length > 1 &&
        (ranked[1].confidence - best.confidence).abs() < .05;
    if (tied) {
      return DuplicateAssessment(
        confidence: best.confidence,
        rationales: best.rationales,
        ambiguous: true,
      );
    }
    return best;
  }

  DuplicateAssessment _score(
    FinancialEventFingerprint incoming,
    LedgerMatchCandidate candidate,
  ) {
    final existing = candidate.fingerprint;
    final rationales = <MatchRationale>[];
    var score = 0.0;

    final reference = _normalize(incoming.reference);
    if (_normalize(incoming.direction) != _normalize(existing.direction)) {
      return const DuplicateAssessment.none();
    }
    if (reference != null && reference == _normalize(existing.reference)) {
      score += .58;
      rationales.add(MatchRationale.transactionReference);
    }
    if (incoming.accountId == existing.accountId &&
        incoming.amountMinor == existing.amountMinor) {
      score += .18;
      rationales.add(MatchRationale.exactAccountAndAmount);
    } else {
      return const DuplicateAssessment.none();
    }
    if (_normalize(incoming.currencyCode) ==
        _normalize(existing.currencyCode)) {
      score += .04;
    }
    score += .07;
    if (_sameNonEmpty(incoming.merchant, existing.merchant)) {
      score += .06;
      rationales.add(MatchRationale.merchantAndAmount);
    }
    if (_sameNonEmpty(incoming.paymentRail, existing.paymentRail)) {
      score += .03;
    }
    final difference = incoming.occurredAt
        .difference(existing.occurredAt)
        .abs();
    if (difference <= const Duration(minutes: 5)) {
      score += .03;
      rationales.add(MatchRationale.timeProximity);
    }
    if (_normalize(incoming.sourcePackage) ==
        _normalize(existing.sourcePackage)) {
      score += .02;
      rationales.add(MatchRationale.sourcePackageRelationship);
    } else if (reference != null) {
      score += .02;
      rationales.add(MatchRationale.sourcePackageRelationship);
    }

    return DuplicateAssessment(
      confidence: score.clamp(0, 1),
      rationales: rationales,
      matchedId: candidate.ledgerEntryId,
    );
  }

  String? _normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  bool _sameNonEmpty(String? left, String? right) {
    final normalized = _normalize(left);
    return normalized != null && normalized == _normalize(right);
  }
}
