import 'dart:convert';

import 'package:expense_tracker/core/models/financial_enums.dart';

class ParsedFinancialEvent {
  const ParsedFinancialEvent({
    this.id,
    required this.rawNotificationEventId,
    required this.eventType,
    required this.status,
    required this.direction,
    this.amountMinor,
    this.currencyCode,
    this.merchantRaw,
    this.merchantNormalized,
    this.institutionId,
    this.instrumentLastFour,
    this.referenceNumber,
    this.paymentRail,
    this.transactionOccurredAt,
    required this.overallConfidence,
    this.fieldConfidence = const {},
    required this.parseDecision,
    this.failureCode,
    this.ledgerDuplicateConfidence = 0,
    this.ledgerDuplicateRationale,
  });

  final int? id;
  final int rawNotificationEventId;
  final FinancialEventType eventType;
  final FinancialEventStatus status;
  final FinancialDirection direction;
  final int? amountMinor;
  final String? currencyCode;
  final String? merchantRaw;
  final String? merchantNormalized;
  final String? institutionId;
  final String? instrumentLastFour;
  final String? referenceNumber;
  final String? paymentRail;
  final DateTime? transactionOccurredAt;
  final double overallConfidence;
  final Map<String, double> fieldConfidence;
  final ParseDecision parseDecision;
  final String? failureCode;
  final double ledgerDuplicateConfidence;
  final String? ledgerDuplicateRationale;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'raw_notification_event_id': rawNotificationEventId,
    'event_type': eventType.storageValue,
    'status': status.storageValue,
    'direction': direction.storageValue,
    'amount_minor': amountMinor,
    'currency_code': currencyCode,
    'merchant_raw': merchantRaw,
    'merchant_normalized': merchantNormalized,
    'institution_id': institutionId,
    'instrument_last_four': instrumentLastFour,
    'reference_number': referenceNumber,
    'payment_rail': paymentRail,
    'transaction_occurred_at': transactionOccurredAt?.toIso8601String(),
    'overall_confidence': overallConfidence,
    'field_confidence': jsonEncode(fieldConfidence),
    'parse_decision': parseDecision.storageValue,
    'failure_code': failureCode,
    'ledger_duplicate_confidence': ledgerDuplicateConfidence,
    'ledger_duplicate_rationale': ledgerDuplicateRationale,
  };

  factory ParsedFinancialEvent.fromMap(Map<String, Object?> map) {
    final decodedConfidence =
        jsonDecode(map['field_confidence'] as String) as Map<String, dynamic>;
    return ParsedFinancialEvent(
      id: map['id'] as int?,
      rawNotificationEventId: map['raw_notification_event_id'] as int,
      eventType: FinancialEventType.fromStorage(map['event_type'] as String),
      status: FinancialEventStatus.fromStorage(map['status'] as String),
      direction: FinancialDirection.fromStorage(map['direction'] as String),
      amountMinor: map['amount_minor'] as int?,
      currencyCode: map['currency_code'] as String?,
      merchantRaw: map['merchant_raw'] as String?,
      merchantNormalized: map['merchant_normalized'] as String?,
      institutionId: map['institution_id'] as String?,
      instrumentLastFour: map['instrument_last_four'] as String?,
      referenceNumber: map['reference_number'] as String?,
      paymentRail: map['payment_rail'] as String?,
      transactionOccurredAt: map['transaction_occurred_at'] == null
          ? null
          : DateTime.parse(map['transaction_occurred_at'] as String),
      overallConfidence: (map['overall_confidence'] as num).toDouble(),
      fieldConfidence: decodedConfidence.map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
      parseDecision: ParseDecision.fromStorage(map['parse_decision'] as String),
      failureCode: map['failure_code'] as String?,
      ledgerDuplicateConfidence:
          (map['ledger_duplicate_confidence'] as num?)?.toDouble() ?? 0,
      ledgerDuplicateRationale: map['ledger_duplicate_rationale'] as String?,
    );
  }
}
