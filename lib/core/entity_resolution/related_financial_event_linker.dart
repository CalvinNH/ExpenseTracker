import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';

class RelatedFinancialEvent {
  const RelatedFinancialEvent({
    required this.eventType,
    required this.direction,
    required this.accountId,
    required this.amountMinor,
    this.merchant,
    this.transactionReference,
    this.refundOrOrderReference,
    required this.occurredAt,
    required this.sourcePackage,
  });

  final FinancialEventType eventType;
  final FinancialDirection direction;
  final int accountId;
  final int amountMinor;
  final String? merchant;
  final String? transactionReference;
  final String? refundOrOrderReference;
  final DateTime occurredAt;
  final String sourcePackage;
}

class RelatedEventCandidate {
  const RelatedEventCandidate({
    required this.transactionGroupId,
    required this.anchor,
  });

  final int transactionGroupId;
  final RelatedFinancialEvent anchor;
}

class RelatedFinancialEventLinker {
  const RelatedFinancialEventLinker();

  DuplicateAssessment link(
    RelatedFinancialEvent incoming,
    List<RelatedEventCandidate> candidates,
  ) {
    final ranked =
        candidates
            .map((candidate) => _score(incoming, candidate))
            .where((assessment) => assessment.confidence >= .5)
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    if (ranked.isEmpty) return const DuplicateAssessment.none();

    final best = ranked.first;
    if (ranked.length > 1 &&
        (ranked[1].confidence - best.confidence).abs() < .05) {
      return DuplicateAssessment(
        confidence: best.confidence,
        rationales: best.rationales,
        ambiguous: true,
      );
    }
    return best.confidence >= .75
        ? best
        : DuplicateAssessment(
            confidence: best.confidence,
            rationales: best.rationales,
          );
  }

  DuplicateAssessment _score(
    RelatedFinancialEvent incoming,
    RelatedEventCandidate candidate,
  ) {
    final anchor = candidate.anchor;
    final rationales = <MatchRationale>[];
    var score = 0.0;

    if (_same(incoming.transactionReference, anchor.transactionReference)) {
      score = .96;
      rationales.add(MatchRationale.transactionReference);
    } else if (_same(
      incoming.refundOrOrderReference,
      anchor.refundOrOrderReference,
    )) {
      score = .91;
      rationales.add(MatchRationale.refundOrOrderReference);
    } else {
      if (incoming.accountId == anchor.accountId &&
          incoming.amountMinor == anchor.amountMinor) {
        score += .52;
        rationales.add(MatchRationale.exactAccountAndAmount);
      }
      if (incoming.amountMinor == anchor.amountMinor &&
          _same(incoming.merchant, anchor.merchant)) {
        score += .16;
        rationales.add(MatchRationale.merchantAndAmount);
      }
      if (_compatibleSequence(incoming, anchor)) {
        score += .13;
        rationales.add(MatchRationale.compatibleEventSequence);
      }
      if (incoming.occurredAt.difference(anchor.occurredAt).abs() <=
          const Duration(days: 14)) {
        score += .06;
        rationales.add(MatchRationale.timeProximity);
      }
      if (_same(incoming.sourcePackage, anchor.sourcePackage)) {
        score += .03;
        rationales.add(MatchRationale.sourcePackageRelationship);
      }
    }

    return DuplicateAssessment(
      confidence: score.clamp(0, 1),
      rationales: rationales,
      matchedId: candidate.transactionGroupId,
    );
  }

  bool _compatibleSequence(
    RelatedFinancialEvent incoming,
    RelatedFinancialEvent anchor,
  ) {
    if (incoming.eventType == FinancialEventType.refund ||
        incoming.eventType == FinancialEventType.reversal) {
      return anchor.direction == FinancialDirection.debit &&
          incoming.direction == FinancialDirection.credit;
    }
    if (incoming.eventType == FinancialEventType.cashback) {
      return incoming.direction == FinancialDirection.credit;
    }
    if (anchor.eventType == FinancialEventType.authorization) {
      return incoming.statusLikeCompletion;
    }
    return incoming.eventType == FinancialEventType.transfer &&
        anchor.eventType == FinancialEventType.transfer &&
        incoming.direction != anchor.direction;
  }

  bool _same(String? left, String? right) {
    final normalized = left?.trim().toLowerCase();
    return normalized != null &&
        normalized.isNotEmpty &&
        normalized == right?.trim().toLowerCase();
  }
}

extension on RelatedFinancialEvent {
  bool get statusLikeCompletion =>
      eventType == FinancialEventType.purchase ||
      eventType == FinancialEventType.transfer;
}

TransactionGroupType transactionGroupTypeFor({
  required FinancialEventType eventType,
  required bool hasOriginalPurchase,
  bool isPartial = false,
}) {
  return switch (eventType) {
    FinancialEventType.purchase => TransactionGroupType.purchase,
    FinancialEventType.refund =>
      isPartial
          ? TransactionGroupType.partialRefund
          : TransactionGroupType.purchaseRefund,
    FinancialEventType.reversal => TransactionGroupType.reversal,
    FinancialEventType.transfer => TransactionGroupType.transfer,
    FinancialEventType.authorization when hasOriginalPurchase =>
      TransactionGroupType.authorizationCompletion,
    FinancialEventType.cashback => TransactionGroupType.cashbackRelated,
    _ => TransactionGroupType.unknown,
  };
}
