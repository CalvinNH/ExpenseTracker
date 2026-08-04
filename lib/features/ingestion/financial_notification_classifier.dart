import 'dart:convert';

class NormalizedNotification {
  const NormalizedNotification({
    required this.originalText,
    required this.comparisonText,
  });

  final String originalText;
  final String comparisonText;
}

enum FinancialRelevance {
  transaction,
  otp,
  promotion,
  balanceOnly,
  creditLimitOnly,
  billReminder,
  minimumDueReminder,
  rewardsOnly,
  unknown,
}

enum FinancialNotificationSemanticFeature {
  transactionAction,
  debitAction,
  creditAction,
  currencyAmount,
  accountInstrument,
  cardInstrument,
  paymentReference,
  vpa,
  otpCredential,
  promotionLanguage,
  rewardsLanguage,
  availableBalance,
  creditLimit,
  billDue,
  minimumDue,
}

enum FinancialNotificationClassifierKind { deterministic, bundledModel }

class ClassificationResult {
  const ClassificationResult({
    required this.relevance,
    required this.confidence,
    required this.features,
    required this.classifierId,
    required this.classifierVersion,
    required this.kind,
    this.modelVersion,
    this.usedFallback = false,
  });

  final FinancialRelevance relevance;
  final double confidence;
  final Set<FinancialNotificationSemanticFeature> features;
  final String classifierId;
  final String classifierVersion;
  final FinancialNotificationClassifierKind kind;

  /// Null for deterministic classifiers. A future bundled model records its
  /// immutable artifact version here without changing persistence structure.
  final String? modelVersion;
  final bool usedFallback;

  ClassificationResult asFallback() => ClassificationResult(
    relevance: relevance,
    confidence: confidence,
    features: features,
    classifierId: classifierId,
    classifierVersion: classifierVersion,
    kind: kind,
    modelVersion: modelVersion,
    usedFallback: true,
  );

  Map<String, Object?> toMetadata() => {
    'schemaVersion': 1,
    'classifierId': classifierId,
    'classifierVersion': classifierVersion,
    'classifierKind': kind.name,
    'modelVersion': modelVersion,
    'confidence': confidence,
    'usedFallback': usedFallback,
    'features': features.map((feature) => feature.name).toList()..sort(),
  };

  String get metadataJson => jsonEncode(toMetadata());
}

abstract interface class FinancialNotificationClassifier {
  ClassificationResult classify(NormalizedNotification notification);
}

/// The default classifier uses only fixed semantic features compiled into the
/// app. Notification content cannot supply executable patterns or rules.
class DeterministicFinancialNotificationClassifier
    implements FinancialNotificationClassifier {
  const DeterministicFinancialNotificationClassifier();

  static const classifierId = 'deterministic_semantic';
  static const classifierVersion = '1';

  static final RegExp _transactionAction = RegExp(
    r'\b(debited|deducted|credited|paid|payment|received|sent|spent|withdrawn|deposited|transfer|transferred|added to balance|refund|refunded|reversed|cashback|purchase|transaction|txn)\b',
    caseSensitive: false,
  );
  static final RegExp _debitAction = RegExp(
    r'\b(debited|deducted|paid|sent|spent|withdrawn)\b',
    caseSensitive: false,
  );
  static final RegExp _creditAction = RegExp(
    r'\b(credited|received|deposited|refund|refunded|reversed|cashback)\b',
    caseSensitive: false,
  );
  static final RegExp _currencyAmount = RegExp(
    r'(?:\binr\b|\brs\.?\b|₹)\s*(?:/-|-)?\s*\d',
    caseSensitive: false,
  );
  static final RegExp _accountInstrument = RegExp(
    r'\b(account|a\s*/\s*c|acct)\b',
    caseSensitive: false,
  );
  static final RegExp _cardInstrument = RegExp(
    r'\b(?:credit\s+card|debit\s+card|card)\b',
    caseSensitive: false,
  );
  static final RegExp _paymentReference = RegExp(
    r'\b(?:utr|rrn|reference|ref|transaction\s*id|txn\s*id|upi\s*ref)\b',
    caseSensitive: false,
  );
  static final RegExp _vpa = RegExp(
    r'\b[a-z0-9._-]{2,}@[a-z][a-z0-9.-]{1,}\b',
    caseSensitive: false,
  );
  static final RegExp _otp = RegExp(
    r'\b(otp|one time password|verification code)\b',
    caseSensitive: false,
  );
  static final RegExp _promotion = RegExp(
    r'\b(offer|sale|discount|promo|coupon)\b',
    caseSensitive: false,
  );
  static final RegExp _rewards = RegExp(
    r'\b(reward points?|loyalty points?)\b',
    caseSensitive: false,
  );
  static final RegExp _availableBalance = RegExp(
    r'\b(available|avl) balance\b',
    caseSensitive: false,
  );
  static final RegExp _creditLimit = RegExp(
    r'\bcredit limit\b',
    caseSensitive: false,
  );
  static final RegExp _billDue = RegExp(
    r'\b(bill due|payment due|due date)\b',
    caseSensitive: false,
  );
  static final RegExp _minimumDue = RegExp(
    r'\b(minimum (?:amount )?due|min due)\b',
    caseSensitive: false,
  );

  @override
  ClassificationResult classify(NormalizedNotification notification) {
    final text = notification.comparisonText;
    final features = <FinancialNotificationSemanticFeature>{};
    _record(
      features,
      text,
      _transactionAction,
      FinancialNotificationSemanticFeature.transactionAction,
    );
    _record(
      features,
      text,
      _debitAction,
      FinancialNotificationSemanticFeature.debitAction,
    );
    _record(
      features,
      text,
      _creditAction,
      FinancialNotificationSemanticFeature.creditAction,
    );
    _record(
      features,
      text,
      _currencyAmount,
      FinancialNotificationSemanticFeature.currencyAmount,
    );
    _record(
      features,
      text,
      _accountInstrument,
      FinancialNotificationSemanticFeature.accountInstrument,
    );
    _record(
      features,
      text,
      _cardInstrument,
      FinancialNotificationSemanticFeature.cardInstrument,
    );
    _record(
      features,
      text,
      _paymentReference,
      FinancialNotificationSemanticFeature.paymentReference,
    );
    _record(features, text, _vpa, FinancialNotificationSemanticFeature.vpa);
    _record(
      features,
      text,
      _otp,
      FinancialNotificationSemanticFeature.otpCredential,
    );
    _record(
      features,
      text,
      _promotion,
      FinancialNotificationSemanticFeature.promotionLanguage,
    );
    _record(
      features,
      text,
      _rewards,
      FinancialNotificationSemanticFeature.rewardsLanguage,
    );
    _record(
      features,
      text,
      _availableBalance,
      FinancialNotificationSemanticFeature.availableBalance,
    );
    _record(
      features,
      text,
      _creditLimit,
      FinancialNotificationSemanticFeature.creditLimit,
    );
    _record(
      features,
      text,
      _billDue,
      FinancialNotificationSemanticFeature.billDue,
    );
    _record(
      features,
      text,
      _minimumDue,
      FinancialNotificationSemanticFeature.minimumDue,
    );

    final hasTransaction = features.contains(
      FinancialNotificationSemanticFeature.transactionAction,
    );
    final relevance = switch (features) {
      _
          when features.contains(
            FinancialNotificationSemanticFeature.otpCredential,
          ) =>
        FinancialRelevance.otp,
      _
          when features.contains(
                FinancialNotificationSemanticFeature.promotionLanguage,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.debitAction,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.creditAction,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.paymentReference,
              ) =>
        FinancialRelevance.promotion,
      _
          when features.contains(
                FinancialNotificationSemanticFeature.rewardsLanguage,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.debitAction,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.creditAction,
              ) &&
              !features.contains(
                FinancialNotificationSemanticFeature.currencyAmount,
              ) =>
        FinancialRelevance.rewardsOnly,
      _
          when features.contains(
            FinancialNotificationSemanticFeature.minimumDue,
          ) =>
        FinancialRelevance.minimumDueReminder,
      _
          when features.contains(
                FinancialNotificationSemanticFeature.billDue,
              ) &&
              !hasTransaction =>
        FinancialRelevance.billReminder,
      _
          when features.contains(
                FinancialNotificationSemanticFeature.creditLimit,
              ) &&
              !hasTransaction =>
        FinancialRelevance.creditLimitOnly,
      _
          when features.contains(
                FinancialNotificationSemanticFeature.availableBalance,
              ) &&
              !hasTransaction =>
        FinancialRelevance.balanceOnly,
      _ when hasTransaction => FinancialRelevance.transaction,
      _ => FinancialRelevance.unknown,
    };
    final confidence = switch (relevance) {
      FinancialRelevance.otp => .99,
      FinancialRelevance.transaction =>
        features.contains(FinancialNotificationSemanticFeature.currencyAmount)
            ? .94
            : .84,
      FinancialRelevance.unknown => .25,
      _ => .9,
    };
    return ClassificationResult(
      relevance: relevance,
      confidence: confidence,
      features: Set.unmodifiable(features),
      classifierId: classifierId,
      classifierVersion: classifierVersion,
      kind: FinancialNotificationClassifierKind.deterministic,
    );
  }

  void _record(
    Set<FinancialNotificationSemanticFeature> features,
    String text,
    RegExp pattern,
    FinancialNotificationSemanticFeature feature,
  ) {
    if (pattern.hasMatch(text)) features.add(feature);
  }
}

/// Wraps a future optional classifier with deterministic safety and fallback.
/// A null, unavailable, or throwing primary never interrupts ingestion.
class ResilientFinancialNotificationClassifier
    implements FinancialNotificationClassifier {
  const ResilientFinancialNotificationClassifier({
    required this.primary,
    this.deterministic = const DeterministicFinancialNotificationClassifier(),
  });

  final FinancialNotificationClassifier? primary;
  final DeterministicFinancialNotificationClassifier deterministic;

  @override
  ClassificationResult classify(NormalizedNotification notification) {
    final baseline = deterministic.classify(notification);
    final candidateClassifier = primary;
    if (candidateClassifier == null) return baseline.asFallback();

    final ClassificationResult candidate;
    try {
      candidate = candidateClassifier.classify(notification);
    } catch (_) {
      return baseline.asFallback();
    }
    if (!_isWellFormed(candidate)) return baseline.asFallback();

    // Deterministic sensitive/non-posting classifications are hard gates. A
    // bundled model may add evidence, but cannot turn these into transactions.
    if (_isDeterministicGate(baseline.relevance) &&
        candidate.relevance != baseline.relevance) {
      return baseline.asFallback();
    }
    return ClassificationResult(
      relevance: candidate.relevance,
      confidence: candidate.confidence,
      features: Set.unmodifiable({...baseline.features, ...candidate.features}),
      classifierId: candidate.classifierId,
      classifierVersion: candidate.classifierVersion,
      kind: candidate.kind,
      modelVersion: candidate.modelVersion,
      usedFallback: candidate.usedFallback,
    );
  }

  bool _isWellFormed(ClassificationResult result) {
    final modelVersion = result.modelVersion;
    return result.confidence.isFinite &&
        result.confidence >= 0 &&
        result.confidence <= 1 &&
        result.classifierId.trim().isNotEmpty &&
        result.classifierVersion.trim().isNotEmpty &&
        (result.kind != FinancialNotificationClassifierKind.bundledModel ||
            (modelVersion != null && modelVersion.trim().isNotEmpty));
  }

  bool _isDeterministicGate(FinancialRelevance relevance) =>
      switch (relevance) {
        FinancialRelevance.otp ||
        FinancialRelevance.promotion ||
        FinancialRelevance.rewardsOnly ||
        FinancialRelevance.balanceOnly ||
        FinancialRelevance.creditLimitOnly ||
        FinancialRelevance.billReminder ||
        FinancialRelevance.minimumDueReminder => true,
        _ => false,
      };
}
