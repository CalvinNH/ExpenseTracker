import 'package:expense_tracker/core/entity_resolution/related_financial_event_linker.dart';
import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final occurredAt = DateTime.utc(2026, 7, 28, 10);

  FinancialEventFingerprint fingerprint({
    int accountId = 1,
    int amountMinor = 100000,
    String? reference,
    String merchant = 'Test Store',
    String sourcePackage = 'bank.app',
    DateTime? time,
  }) {
    return FinancialEventFingerprint(
      amountMinor: amountMinor,
      currencyCode: 'INR',
      direction: 'debit',
      accountId: accountId,
      merchant: merchant,
      reference: reference,
      paymentRail: 'upi',
      occurredAt: time ?? occurredAt,
      sourcePackage: sourcePackage,
    );
  }

  test('same reference number across sources is a definitive duplicate', () {
    final result = const LedgerDuplicateDetector()
        .assess(fingerprint(reference: 'UTR123456', sourcePackage: 'upi.app'), [
          LedgerMatchCandidate(
            ledgerEntryId: 7,
            fingerprint: fingerprint(reference: 'UTR123456'),
          ),
        ]);

    expect(result.isDefinitive, isTrue);
    expect(result.matchedId, 7);
    expect(result.rationales, contains(MatchRationale.transactionReference));
    expect(result.confidence, greaterThanOrEqualTo(.85));
  });

  test('time proximity alone never suppresses a real same-amount event', () {
    final result = const LedgerDuplicateDetector().assess(
      fingerprint(
        reference: 'UTR-B',
        time: occurredAt.add(const Duration(seconds: 20)),
      ),
      [
        LedgerMatchCandidate(
          ledgerEntryId: 7,
          fingerprint: fingerprint(reference: 'UTR-A'),
        ),
      ],
    );

    expect(result.isDefinitive, isFalse);
    expect(result.confidence, lessThan(.85));
  });

  test('same amount and merchant on different accounts never match', () {
    final result = const LedgerDuplicateDetector()
        .assess(fingerprint(accountId: 2, reference: 'UTR-B'), [
          LedgerMatchCandidate(
            ledgerEntryId: 7,
            fingerprint: fingerprint(accountId: 1, reference: 'UTR-A'),
          ),
        ]);

    expect(result.matchedId, isNull);
    expect(result.confidence, 0);
  });

  test('ambiguous related-event candidates are not forced into a group', () {
    final incoming = RelatedFinancialEvent(
      eventType: FinancialEventType.refund,
      direction: FinancialDirection.credit,
      accountId: 1,
      amountMinor: 100000,
      merchant: 'Test Store',
      occurredAt: occurredAt.add(const Duration(days: 1)),
      sourcePackage: 'bank.app',
    );
    final anchor = RelatedFinancialEvent(
      eventType: FinancialEventType.purchase,
      direction: FinancialDirection.debit,
      accountId: 1,
      amountMinor: 100000,
      merchant: 'Test Store',
      occurredAt: occurredAt,
      sourcePackage: 'bank.app',
    );

    final result = const RelatedFinancialEventLinker().link(incoming, [
      RelatedEventCandidate(transactionGroupId: 10, anchor: anchor),
      RelatedEventCandidate(transactionGroupId: 20, anchor: anchor),
    ]);

    expect(result.ambiguous, isTrue);
    expect(result.matchedId, isNull);
  });

  test('group type vocabulary covers related financial event concepts', () {
    expect(
      transactionGroupTypeFor(
        eventType: FinancialEventType.refund,
        hasOriginalPurchase: true,
      ),
      TransactionGroupType.purchaseRefund,
    );
    expect(
      transactionGroupTypeFor(
        eventType: FinancialEventType.refund,
        hasOriginalPurchase: true,
        isPartial: true,
      ),
      TransactionGroupType.partialRefund,
    );
    expect(
      transactionGroupTypeFor(
        eventType: FinancialEventType.cashback,
        hasOriginalPurchase: true,
      ),
      TransactionGroupType.cashbackRelated,
    );
  });
}
