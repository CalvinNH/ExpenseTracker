import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';

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

enum MonetarySemanticRole {
  transactionAmount,
  availableBalance,
  outstandingBalance,
  creditLimit,
  minimumDue,
  fee,
  refundAmount,
  unknown,
}

class MonetaryCandidate {
  const MonetaryCandidate({
    required this.amountMinor,
    required this.currency,
    required this.start,
    required this.end,
    required this.contextWindow,
    required this.semanticRole,
    required this.confidence,
  });

  final int amountMinor;
  final String currency;
  final int start;
  final int end;
  final String contextWindow;
  final MonetarySemanticRole semanticRole;
  final double confidence;
}

class ExtractedField<T> {
  const ExtractedField(this.value, this.confidence);
  final T value;
  final double confidence;
}

class InstrumentEvidence {
  const InstrumentEvidence({this.lastFour, this.raw});
  final String? lastFour;
  final String? raw;
}

class MerchantEvidence {
  const MerchantEvidence({
    required this.raw,
    required this.normalized,
    required this.confidence,
  });
  final String? raw;
  final String? normalized;
  final double confidence;
}

class ParseValidation {
  const ParseValidation({required this.decision, this.failureCode});
  final ParseDecision decision;
  final String? failureCode;
}

class ConfidenceThresholds {
  const ConfidenceThresholds({
    this.autoPost = 0.75,
    this.provisional = 0.55,
    this.transactionAmount = 0.65,
  });
  final double autoPost;
  final double provisional;
  final double transactionAmount;
}

class FinancialParseResult {
  const FinancialParseResult({
    required this.normalized,
    required this.relevance,
    required this.amountCandidates,
    required this.selectedAmount,
    required this.direction,
    required this.status,
    required this.eventType,
    required this.instrument,
    required this.institutionId,
    required this.referenceNumber,
    required this.merchant,
    required this.transactionTime,
    required this.fieldConfidence,
    required this.overallConfidence,
    required this.decision,
    this.failureCode,
  });

  final NormalizedNotification normalized;
  final FinancialRelevance relevance;
  final List<MonetaryCandidate> amountCandidates;
  final MonetaryCandidate? selectedAmount;
  final FinancialDirection direction;
  final FinancialEventStatus status;
  final FinancialEventType eventType;
  final InstrumentEvidence instrument;
  final String? institutionId;
  final String? referenceNumber;
  final MerchantEvidence merchant;
  final DateTime? transactionTime;
  final Map<String, double> fieldConfidence;
  final double overallConfidence;
  final ParseDecision decision;
  final String? failureCode;
}

abstract interface class NotificationNormalizer {
  NormalizedNotification normalize(String title, String content);
}

abstract interface class FinancialRelevanceClassifier {
  FinancialRelevance classify(NormalizedNotification input);
}

abstract interface class AmountExtractor {
  List<MonetaryCandidate> extract(NormalizedNotification input);
}

abstract interface class DirectionExtractor {
  ExtractedField<FinancialDirection> extract(NormalizedNotification input);
}

abstract interface class StatusExtractor {
  ExtractedField<FinancialEventStatus> extract(NormalizedNotification input);
}

abstract interface class EventTypeExtractor {
  ExtractedField<FinancialEventType> extract(NormalizedNotification input);
}

abstract interface class InstrumentExtractor {
  ExtractedField<InstrumentEvidence> extract(NormalizedNotification input);
}

abstract interface class InstitutionExtractor {
  ExtractedField<String?> extract(
    NormalizedNotification input, {
    String? sourcePackage,
  });
}

abstract interface class ReferenceExtractor {
  ExtractedField<String?> extract(NormalizedNotification input);
}

abstract interface class MerchantExtractor {
  MerchantEvidence extract(
    NormalizedNotification input, {
    String? sourcePackage,
  });
}

abstract interface class TransactionTimeExtractor {
  ExtractedField<DateTime?> extract(NormalizedNotification input);
}

abstract interface class ConfidenceCalculator {
  ({Map<String, double> fields, double overall}) calculate({
    required MonetaryCandidate? amount,
    required ExtractedField<FinancialDirection> direction,
    required ExtractedField<FinancialEventStatus> status,
    required ExtractedField<FinancialEventType> eventType,
    required ExtractedField<InstrumentEvidence> instrument,
    required ExtractedField<String?> institution,
    required ExtractedField<String?> reference,
    required MerchantEvidence merchant,
    required bool knownPackage,
    required bool recognizedTransactionPhrase,
  });
}

abstract interface class ParseValidator {
  ParseValidation validate({
    required FinancialRelevance relevance,
    required MonetaryCandidate? amount,
    required FinancialDirection direction,
    required FinancialEventStatus status,
    required double overallConfidence,
  });
}

class DefaultNotificationNormalizer implements NotificationNormalizer {
  @override
  NormalizedNotification normalize(String title, String content) {
    final original = '$title $content'
        .replaceAll(RegExp(r'[\u00A0\u2000-\u200B\u202F\u205F\u3000]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    var comparison = original.toLowerCase();
    comparison = comparison
        .replaceAll(RegExp(r'\b(?:rupees?|inr|rs\.?)\s*/?-?'), ' inr ')
        .replaceAll('₹', ' inr ')
        .replaceAll(RegExp(r'\ba\s*/\s*c\b|\bacct?\b'), 'account')
        .replaceAll(RegExp(r'\bc\s*/\s*c\b'), 'credit card')
        .replaceAll(RegExp(r'\bcr\b'), 'credited')
        .replaceAll(RegExp(r'\bdr\b'), 'debited')
        .replaceAll(RegExp(r'[x*•●·.]{2,}(?=\d)'), 'xxxx')
        .replaceAllMapped(RegExp(r'([!?.,;:])\1+'), (match) => match.group(1)!)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return NormalizedNotification(
      originalText: original,
      comparisonText: comparison,
    );
  }
}

class DefaultFinancialRelevanceClassifier
    implements FinancialRelevanceClassifier {
  @override
  FinancialRelevance classify(NormalizedNotification input) {
    final text = input.comparisonText;
    if (_has(text, r'\b(otp|one time password|verification code)\b')) {
      return FinancialRelevance.otp;
    }
    if (_has(text, r'\b(offer|sale|discount|promo|coupon)\b') &&
        !_transactionPhrase(text)) {
      return FinancialRelevance.promotion;
    }
    if (_has(text, r'\b(reward points?|loyalty points?)\b') &&
        !_transactionPhrase(text)) {
      return FinancialRelevance.rewardsOnly;
    }
    if (_has(text, r'\b(minimum (?:amount )?due|min due)\b')) {
      return FinancialRelevance.minimumDueReminder;
    }
    if (_has(text, r'\b(bill due|payment due|due date)\b') &&
        !_transactionPhrase(text)) {
      return FinancialRelevance.billReminder;
    }
    if (_has(text, r'\bcredit limit\b') && !_transactionPhrase(text)) {
      return FinancialRelevance.creditLimitOnly;
    }
    if (_has(text, r'\b(available|avl) balance\b') &&
        !_transactionPhrase(text)) {
      return FinancialRelevance.balanceOnly;
    }
    return _transactionPhrase(text)
        ? FinancialRelevance.transaction
        : FinancialRelevance.unknown;
  }
}

class DefaultAmountExtractor implements AmountExtractor {
  static final _amountPattern = RegExp(
    r'(?:₹|inr|rs\.?|rupees?)\s*(?:/-|-)?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
    caseSensitive: false,
  );

  @override
  List<MonetaryCandidate> extract(NormalizedNotification input) {
    final result = <MonetaryCandidate>[];
    for (final match in _amountPattern.allMatches(input.originalText)) {
      final number = double.tryParse(match.group(1)!.replaceAll(',', ''));
      if (number == null || !number.isFinite || number <= 0) continue;
      final start = (match.start - 45).clamp(0, input.originalText.length);
      final end = (match.end + 45).clamp(0, input.originalText.length);
      final context = input.originalText.substring(start, end);
      final role = _role(context, match.start - start);
      final amountMinor = majorToMinor(number);
      if (amountMinor > 1000000000) continue;
      final confidence = switch (role) {
        MonetarySemanticRole.transactionAmount ||
        MonetarySemanticRole.refundAmount ||
        MonetarySemanticRole.fee => 0.92,
        MonetarySemanticRole.unknown => 0.45,
        _ => 0.9,
      };
      result.add(
        MonetaryCandidate(
          amountMinor: amountMinor,
          currency: 'INR',
          start: match.start,
          end: match.end,
          contextWindow: context,
          semanticRole: role,
          confidence: confidence,
        ),
      );
    }
    return result;
  }

  MonetarySemanticRole _role(String context, int amountOffset) {
    final lower = context.toLowerCase();
    final cues = <MonetarySemanticRole, RegExp>{
      MonetarySemanticRole.availableBalance: RegExp(
        r'\b(available|avl) bal(?:ance)?\b',
      ),
      MonetarySemanticRole.outstandingBalance: RegExp(r'\boutstanding\b'),
      MonetarySemanticRole.creditLimit: RegExp(r'\bcredit limit\b'),
      MonetarySemanticRole.minimumDue: RegExp(r'\bminimum (?:amount )?due\b'),
      MonetarySemanticRole.refundAmount: RegExp(r'\b(refund|refunded)\b'),
      MonetarySemanticRole.fee: RegExp(r'\b(fee|charge)\b'),
      MonetarySemanticRole.transactionAmount: RegExp(
        r'\b(debited|credited|paid|payment|received|sent|withdrawn|deposited|spent|purchase|txn|transaction|transferred|refund|reversal|cashback)\b',
      ),
    };
    var result = MonetarySemanticRole.unknown;
    var bestDistance = 1 << 30;
    for (final entry in cues.entries) {
      for (final match in entry.value.allMatches(lower)) {
        final distance = amountOffset < match.start
            ? match.start - amountOffset
            : amountOffset > match.end
            ? amountOffset - match.end
            : 0;
        if (distance < bestDistance) {
          bestDistance = distance;
          result = entry.key;
        }
      }
    }
    return result;
  }
}

class DefaultDirectionExtractor implements DirectionExtractor {
  @override
  ExtractedField<FinancialDirection> extract(NormalizedNotification input) {
    final text = input.comparisonText;
    final credit = _has(
      text,
      r'\b(credited|received|deposited|added to balance|refund(?:ed| initiated)?|cashback|reversed)\b',
    );
    final debit = _has(
      text,
      r'\b(debited|paid|sent|spent|withdrawn|deducted|purchased)\b',
    );
    // Card-network notifications sometimes omit an explicit debit verb, but a
    // card transaction amount followed by a merchant is an unambiguous spend.
    final cardMerchantPurchase = _has(
      text,
      r'\btransaction\s+of\b(?=.{0,100}\b(?:card|merchant|at)\b)',
    );
    if (credit && debit) {
      if (_has(
        text,
        r'\b(refund(?:ed| credited| initiated)?|reversed|cashback)\b',
      )) {
        return const ExtractedField(FinancialDirection.credit, 0.9);
      }
      return const ExtractedField(FinancialDirection.unknown, 0.2);
    }
    if (credit) return const ExtractedField(FinancialDirection.credit, 0.95);
    if (debit || cardMerchantPurchase) {
      return ExtractedField(
        FinancialDirection.debit,
        debit ? 0.95 : 0.78,
      );
    }
    return const ExtractedField(FinancialDirection.unknown, 0);
  }
}

class DefaultStatusExtractor implements StatusExtractor {
  @override
  ExtractedField<FinancialEventStatus> extract(NormalizedNotification input) {
    final text = input.comparisonText;
    if (_has(text, r'\b(failed|unsuccessful|could not be processed)\b')) {
      return const ExtractedField(FinancialEventStatus.failed, 0.98);
    }
    if (_has(text, r'\b(declined|rejected)\b')) {
      return const ExtractedField(FinancialEventStatus.declined, 0.98);
    }
    if (_has(text, r'\b(pending|processing|scheduled)\b')) {
      return const ExtractedField(FinancialEventStatus.pending, 0.95);
    }
    if (_has(text, r'\b(refund initiated|initiated)\b')) {
      return const ExtractedField(FinancialEventStatus.initiated, 0.95);
    }
    if (_has(text, r'\b(reversed|reversal completed)\b')) {
      return const ExtractedField(FinancialEventStatus.reversed, 0.95);
    }
    if (_transactionPhrase(text)) {
      return const ExtractedField(FinancialEventStatus.completed, 0.82);
    }
    return const ExtractedField(FinancialEventStatus.unknown, 0);
  }
}

class DefaultEventTypeExtractor implements EventTypeExtractor {
  @override
  ExtractedField<FinancialEventType> extract(NormalizedNotification input) {
    final text = input.comparisonText;
    const confidence = 0.9;
    if (_has(text, r'\bcashback\b')) {
      return const ExtractedField(FinancialEventType.cashback, confidence);
    }
    if (_has(text, r'\brefund')) {
      return const ExtractedField(FinancialEventType.refund, confidence);
    }
    if (_has(text, r'\brevers')) {
      return const ExtractedField(FinancialEventType.reversal, confidence);
    }
    if (_has(text, r'\bwithdraw')) {
      return const ExtractedField(FinancialEventType.withdrawal, confidence);
    }
    if (_has(text, r'\bdeposit')) {
      return const ExtractedField(FinancialEventType.deposit, confidence);
    }
    if (_has(text, r'\b(fee|charge)\b')) {
      return const ExtractedField(FinancialEventType.fee, confidence);
    }
    if (_has(text, r'\b(authori[sz](?:ed|ation)|blocked)\b')) {
      return const ExtractedField(FinancialEventType.authorization, confidence);
    }
    if (_has(text, r'\b(transfer(?:red)?|sent to|received from)\b')) {
      return const ExtractedField(FinancialEventType.transfer, confidence);
    }
    if (_has(text, r'\b(salary|income|dividend|interest credited)\b')) {
      return const ExtractedField(FinancialEventType.income, confidence);
    }
    if (_has(text, r'\bcredited\b')) {
      return const ExtractedField(FinancialEventType.deposit, confidence);
    }
    if (_has(text, r'\b(available balance|credit limit)\b') &&
        !_transactionPhrase(text)) {
      return const ExtractedField(FinancialEventType.balanceAlert, confidence);
    }
    if (_transactionPhrase(text)) {
      return const ExtractedField(FinancialEventType.purchase, 0.75);
    }
    return const ExtractedField(FinancialEventType.unknown, 0);
  }
}

class DefaultInstrumentExtractor implements InstrumentExtractor {
  @override
  ExtractedField<InstrumentEvidence> extract(NormalizedNotification input) {
    final match = RegExp(
      r'(?:account|card|ending|[x*•●.]{2,})[^0-9]{0,12}(?:[x*•●.]*)?(\d{4,})',
      caseSensitive: false,
    ).firstMatch(input.comparisonText);
    if (match == null) {
      return const ExtractedField(InstrumentEvidence(), 0);
    }
    final digits = match.group(1)!;
    return ExtractedField(
      InstrumentEvidence(
        lastFour: digits.substring(digits.length - 4),
        raw: match.group(0),
      ),
      0.95,
    );
  }
}

class DefaultInstitutionExtractor implements InstitutionExtractor {
  static const _institutions = {
    'hdfc': 'hdfc',
    'state bank of india': 'sbi',
    'sbi': 'sbi',
    'icici': 'icici',
    'axis': 'axis',
    'kotak': 'kotak',
    'pnb': 'pnb',
    'punjab national bank': 'pnb',
    'bank of baroda': 'bob',
    'canara bank': 'canara',
    'union bank': 'union',
    'idfc': 'idfc',
    'paytm wallet': 'paytm_wallet',
    // Notification-listener test sources can be the Android shell rather than
    // the wallet package, so title/content remains the local identity signal.
    'paytm': 'paytm_wallet',
    'amazon pay': 'amazon_pay_wallet',
    'idfc': 'idfc',
    'indusind': 'indusind',
    'yes bank': 'yes',
  };

  @override
  ExtractedField<String?> extract(
    NormalizedNotification input, {
    String? sourcePackage,
  }) {
    for (final entry in _institutions.entries) {
      if (input.comparisonText.contains(entry.key)) {
        return ExtractedField(entry.value, 0.9);
      }
    }
    if (sourcePackage != null) {
      for (final code in _institutions.values.toSet()) {
        if (sourcePackage.toLowerCase().contains(code)) {
          return ExtractedField(code, 0.75);
        }
      }
    }
    return const ExtractedField(null, 0);
  }
}

class DefaultReferenceExtractor implements ReferenceExtractor {
  @override
  ExtractedField<String?> extract(NormalizedNotification input) {
    final match = RegExp(
      r'\b(?:utr|rrn|ref(?:erence)?|txn(?:\s+id)?|transaction\s+id|upi ref)\s*[:#-]?\s*([a-z0-9/-]{6,30})\b',
      caseSensitive: false,
    ).firstMatch(input.originalText);
    return match == null
        ? const ExtractedField(null, 0)
        : ExtractedField(match.group(1), 0.98);
  }
}

class DefaultMerchantExtractor implements MerchantExtractor {
  static const aliases = {
    'zomato': 'Zomato',
    'swiggy': 'Swiggy',
    'amazon': 'Amazon',
    'flipkart': 'Flipkart',
    'uber': 'Uber',
    'ola': 'Ola',
    'myntra': 'Myntra',
    'starbucks': 'Starbucks',
    'netflix': 'Netflix',
  };

  @override
  MerchantEvidence extract(
    NormalizedNotification input, {
    String? sourcePackage,
  }) {
    final upi = RegExp(
      r'\bupi[/\-]([a-z][a-z0-9 .&_-]{1,60}?)(?:[/\-]\d+|[.;,]|$)',
      caseSensitive: false,
    ).firstMatch(input.originalText);
    if (upi != null) return _merchant(upi.group(1)!, 0.92);

    final prefixed = RegExp(
      r'\b(?:at|to|for|merchant|info|vpa)\s*[:\-]?\s*([a-z0-9][a-z0-9 _/@.&\-]{1,80}?)(?=\s+(?:on|via|using|ref|txn|avl|balance|from|account|card)\b|[.;,]|$)',
      caseSensitive: false,
    ).allMatches(input.originalText);
    for (final match in prefixed) {
      final raw = match.group(1)!.trim();
      if (!_invalidMerchant(raw)) return _merchant(raw, 0.88);
    }
    for (final entry in aliases.entries) {
      if (_has(input.comparisonText, '\\b${entry.key}\\b')) {
        return _merchant(entry.value, 0.78);
      }
    }
    if (sourcePackage != null) {
      for (final entry in aliases.entries) {
        if (sourcePackage.toLowerCase().contains(entry.key)) {
          return _merchant(entry.value, 0.65);
        }
      }
    }
    return const MerchantEvidence(raw: null, normalized: null, confidence: 0);
  }

  MerchantEvidence _merchant(String raw, double confidence) {
    var normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    normalized = normalized.replaceAll(
      RegExp(
        r'\s+(?:pvt\.?\s*ltd\.?|private limited|limited|ltd\.?|llp|inc\.?|corporation|corp\.?)$',
        caseSensitive: false,
      ),
      '',
    );
    return MerchantEvidence(
      raw: raw.trim(),
      normalized: normalized,
      confidence: confidence,
    );
  }

  bool _invalidMerchant(String value) => RegExp(
    r'^(?:inr|rs|a/?c|account|card|bank|\d)|\b(?:bank|card|account|a/?c)\b',
    caseSensitive: false,
  ).hasMatch(value);
}

class DefaultTransactionTimeExtractor implements TransactionTimeExtractor {
  @override
  ExtractedField<DateTime?> extract(NormalizedNotification input) {
    final match = RegExp(
      r'\b(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})(?:\s+(?:at\s+)?(\d{1,2}):(\d{2}))?',
      caseSensitive: false,
    ).firstMatch(input.originalText);
    if (match == null) return const ExtractedField(null, 0);
    final yearValue = int.parse(match.group(3)!);
    final year = yearValue < 100 ? 2000 + yearValue : yearValue;
    try {
      return ExtractedField(
        DateTime(
          year,
          int.parse(match.group(2)!),
          int.parse(match.group(1)!),
          int.tryParse(match.group(4) ?? '') ?? 0,
          int.tryParse(match.group(5) ?? '') ?? 0,
        ),
        0.85,
      );
    } on ArgumentError {
      return const ExtractedField(null, 0);
    }
  }
}

class DefaultConfidenceCalculator implements ConfidenceCalculator {
  @override
  ({Map<String, double> fields, double overall}) calculate({
    required MonetaryCandidate? amount,
    required ExtractedField<FinancialDirection> direction,
    required ExtractedField<FinancialEventStatus> status,
    required ExtractedField<FinancialEventType> eventType,
    required ExtractedField<InstrumentEvidence> instrument,
    required ExtractedField<String?> institution,
    required ExtractedField<String?> reference,
    required MerchantEvidence merchant,
    required bool knownPackage,
    required bool recognizedTransactionPhrase,
  }) {
    final fields = <String, double>{
      'amount': amount?.confidence ?? 0,
      'direction': direction.confidence,
      'status': status.confidence,
      'eventType': eventType.confidence,
      'instrument': instrument.confidence,
      'institution': institution.confidence,
      'reference': reference.confidence,
      'merchant': merchant.confidence,
      'knownPackage': knownPackage ? 0.9 : 0,
      'transactionPhrase': recognizedTransactionPhrase ? 0.9 : 0,
    };
    final strong = fields.values.where((value) => value >= 0.75).toList();
    final overall = strong.isEmpty
        ? 0.0
        : (strong.reduce((a, b) => a + b) / strong.length).clamp(0.0, 1.0);
    return (fields: fields, overall: overall);
  }
}

class DefaultParseValidator implements ParseValidator {
  DefaultParseValidator({this.thresholds = const ConfidenceThresholds()});
  final ConfidenceThresholds thresholds;

  @override
  ParseValidation validate({
    required FinancialRelevance relevance,
    required MonetaryCandidate? amount,
    required FinancialDirection direction,
    required FinancialEventStatus status,
    required double overallConfidence,
  }) {
    if (relevance == FinancialRelevance.otp ||
        relevance == FinancialRelevance.promotion ||
        relevance == FinancialRelevance.rewardsOnly) {
      return const ParseValidation(
        decision: ParseDecision.ignored,
        failureCode: 'non_financial_or_sensitive',
      );
    }
    if (relevance == FinancialRelevance.balanceOnly ||
        relevance == FinancialRelevance.creditLimitOnly ||
        relevance == FinancialRelevance.billReminder ||
        relevance == FinancialRelevance.minimumDueReminder) {
      return const ParseValidation(
        decision: ParseDecision.retainOnly,
        failureCode: 'non_posting_financial_alert',
      );
    }
    if (status == FinancialEventStatus.failed ||
        status == FinancialEventStatus.declined) {
      return ParseValidation(
        decision: ParseDecision.retainOnly,
        failureCode: 'status_${status.name}',
      );
    }
    if (status == FinancialEventStatus.pending ||
        status == FinancialEventStatus.initiated) {
      return ParseValidation(
        decision: ParseDecision.retainOnly,
        failureCode: 'status_${status.name}',
      );
    }
    if (amount == null || amount.confidence < thresholds.transactionAmount) {
      return const ParseValidation(
        decision: ParseDecision.retainOnly,
        failureCode: 'transaction_amount_missing',
      );
    }
    if (direction == FinancialDirection.unknown ||
        direction == FinancialDirection.none) {
      return const ParseValidation(
        decision: ParseDecision.provisional,
        failureCode: 'direction_unresolved',
      );
    }
    if (overallConfidence >= thresholds.autoPost) {
      return const ParseValidation(decision: ParseDecision.autoPost);
    }
    if (overallConfidence >= thresholds.provisional) {
      return const ParseValidation(
        decision: ParseDecision.provisional,
        failureCode: 'confidence_provisional',
      );
    }
    return const ParseValidation(
      decision: ParseDecision.retainOnly,
      failureCode: 'confidence_low',
    );
  }
}

class NotificationParsingPipeline {
  NotificationParsingPipeline({
    NotificationNormalizer? normalizer,
    FinancialRelevanceClassifier? relevanceClassifier,
    AmountExtractor? amountExtractor,
    DirectionExtractor? directionExtractor,
    StatusExtractor? statusExtractor,
    EventTypeExtractor? eventTypeExtractor,
    InstrumentExtractor? instrumentExtractor,
    InstitutionExtractor? institutionExtractor,
    ReferenceExtractor? referenceExtractor,
    MerchantExtractor? merchantExtractor,
    TransactionTimeExtractor? transactionTimeExtractor,
    ConfidenceCalculator? confidenceCalculator,
    ParseValidator? validator,
  }) : normalizer = normalizer ?? DefaultNotificationNormalizer(),
       relevanceClassifier =
           relevanceClassifier ?? DefaultFinancialRelevanceClassifier(),
       amountExtractor = amountExtractor ?? DefaultAmountExtractor(),
       directionExtractor = directionExtractor ?? DefaultDirectionExtractor(),
       statusExtractor = statusExtractor ?? DefaultStatusExtractor(),
       eventTypeExtractor = eventTypeExtractor ?? DefaultEventTypeExtractor(),
       instrumentExtractor =
           instrumentExtractor ?? DefaultInstrumentExtractor(),
       institutionExtractor =
           institutionExtractor ?? DefaultInstitutionExtractor(),
       referenceExtractor = referenceExtractor ?? DefaultReferenceExtractor(),
       merchantExtractor = merchantExtractor ?? DefaultMerchantExtractor(),
       transactionTimeExtractor =
           transactionTimeExtractor ?? DefaultTransactionTimeExtractor(),
       confidenceCalculator =
           confidenceCalculator ?? DefaultConfidenceCalculator(),
       validator = validator ?? DefaultParseValidator();

  final NotificationNormalizer normalizer;
  final FinancialRelevanceClassifier relevanceClassifier;
  final AmountExtractor amountExtractor;
  final DirectionExtractor directionExtractor;
  final StatusExtractor statusExtractor;
  final EventTypeExtractor eventTypeExtractor;
  final InstrumentExtractor instrumentExtractor;
  final InstitutionExtractor institutionExtractor;
  final ReferenceExtractor referenceExtractor;
  final MerchantExtractor merchantExtractor;
  final TransactionTimeExtractor transactionTimeExtractor;
  final ConfidenceCalculator confidenceCalculator;
  final ParseValidator validator;

  FinancialParseResult parse(
    String title,
    String content, {
    String? sourcePackage,
    bool knownPackage = false,
  }) {
    final normalized = normalizer.normalize(title, content);
    final relevance = relevanceClassifier.classify(normalized);
    final amounts = amountExtractor.extract(normalized);
    final selectedAmount = _selectAmount(amounts);
    final direction = directionExtractor.extract(normalized);
    final status = statusExtractor.extract(normalized);
    final eventType = eventTypeExtractor.extract(normalized);
    final instrument = instrumentExtractor.extract(normalized);
    final institution = institutionExtractor.extract(
      normalized,
      sourcePackage: sourcePackage,
    );
    final reference = referenceExtractor.extract(normalized);
    final merchant = merchantExtractor.extract(
      normalized,
      sourcePackage: sourcePackage,
    );
    final time = transactionTimeExtractor.extract(normalized);
    final confidence = confidenceCalculator.calculate(
      amount: selectedAmount,
      direction: direction,
      status: status,
      eventType: eventType,
      instrument: instrument,
      institution: institution,
      reference: reference,
      merchant: merchant,
      knownPackage: knownPackage,
      recognizedTransactionPhrase: _transactionPhrase(
        normalized.comparisonText,
      ),
    );
    final validation = validator.validate(
      relevance: relevance,
      amount: selectedAmount,
      direction: direction.value,
      status: status.value,
      overallConfidence: confidence.overall,
    );
    return FinancialParseResult(
      normalized: normalized,
      relevance: relevance,
      amountCandidates: amounts,
      selectedAmount: selectedAmount,
      direction: direction.value,
      status: status.value,
      eventType: eventType.value,
      instrument: instrument.value,
      institutionId: institution.value,
      referenceNumber: reference.value,
      merchant: merchant,
      transactionTime: time.value,
      fieldConfidence: confidence.fields,
      overallConfidence: confidence.overall,
      decision: validation.decision,
      failureCode: validation.failureCode,
    );
  }

  MonetaryCandidate? _selectAmount(List<MonetaryCandidate> candidates) {
    final relevant =
        candidates
            .where(
              (candidate) =>
                  candidate.semanticRole ==
                      MonetarySemanticRole.transactionAmount ||
                  candidate.semanticRole == MonetarySemanticRole.refundAmount ||
                  candidate.semanticRole == MonetarySemanticRole.fee,
            )
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return relevant.isEmpty ? null : relevant.first;
  }
}

bool _has(String text, String pattern) =>
    RegExp(pattern, caseSensitive: false).hasMatch(text);

bool _transactionPhrase(String text) => _has(
  text,
  r'\b(debited|credited|paid|payment|received|sent|spent|withdrawn|deposited|transferred|added to balance|refund|refunded|reversed|cashback|purchase|transaction|txn)\b',
);
