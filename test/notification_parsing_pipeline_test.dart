import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/notification_parser_fixtures.dart';

void main() {
  group('fixture-driven parsing corpus', () {
    final pipeline = NotificationParsingPipeline();
    for (final fixture in parserFixtures) {
      test(fixture.name, () {
        final result = pipeline.parse(
          'Bank alert',
          fixture.content,
          sourcePackage: 'com.example.bank',
          knownPackage: true,
        );

        expect(result.selectedAmount?.amountMinor, fixture.amountMinor);
        expect(result.direction, fixture.direction);
        expect(result.status, fixture.status);
        expect(result.eventType, fixture.eventType);
        expect(result.decision, fixture.decision);
      });
    }
  });

  group('independently testable stages', () {
    test('normalizer preserves evidence and normalizes comparison text', () {
      final result = DefaultNotificationNormalizer().normalize(
        'Alert',
        'Rs./-\u00a01,000••••1234  DEBITED!!',
      );

      expect(result.originalText, contains('Rs./-'));
      expect(result.comparisonText, contains('inr'));
      expect(result.comparisonText, contains('debited!'));
      expect(result.comparisonText, isNot(contains('\u00a0')));
    });

    test('amount extractor returns every candidate with ranges and roles', () {
      final normalized = DefaultNotificationNormalizer().normalize(
        '',
        'Available balance INR 9,000. INR 250 paid at Cafe.',
      );
      final candidates = DefaultAmountExtractor().extract(normalized);

      expect(candidates, hasLength(2));
      expect(
        candidates.first.semanticRole,
        MonetarySemanticRole.availableBalance,
      );
      expect(
        candidates.last.semanticRole,
        MonetarySemanticRole.transactionAmount,
      );
      for (final candidate in candidates) {
        expect(candidate.start, lessThan(candidate.end));
        expect(candidate.contextWindow, isNotEmpty);
        expect(candidate.currency, 'INR');
        expect(candidate.confidence, inInclusiveRange(0, 1));
      }
    });

    test(
      'direction never defaults to debit and conflicting cues are unknown',
      () {
        final normalizer = DefaultNotificationNormalizer();
        final extractor = DefaultDirectionExtractor();

        expect(
          extractor
              .extract(normalizer.normalize('', 'Transaction INR 50'))
              .value,
          FinancialDirection.unknown,
        );
        expect(
          extractor
              .extract(normalizer.normalize('', 'INR 50 debited and credited'))
              .value,
          FinancialDirection.unknown,
        );
      },
    );

    test('status is extracted before validator permits posting', () {
      final normalized = DefaultNotificationNormalizer().normalize(
        '',
        'INR 500 paid at Cafe is pending',
      );
      final status = DefaultStatusExtractor().extract(normalized);
      final validation = DefaultParseValidator().validate(
        relevance: FinancialRelevance.transaction,
        amount: DefaultAmountExtractor().extract(normalized).single,
        direction: FinancialDirection.debit,
        status: status.value,
        overallConfidence: 1,
      );

      expect(status.value, FinancialEventStatus.pending);
      expect(validation.decision, ParseDecision.retainOnly);
      expect(validation.failureCode, 'status_pending');
    });

    test(
      'merchant keeps raw name and strips legal suffix only when normalized',
      () {
        final merchant = DefaultMerchantExtractor().extract(
          DefaultNotificationNormalizer().normalize(
            '',
            'INR 500 paid at Example Foods Private Limited.',
          ),
        );

        expect(merchant.raw, 'Example Foods Private Limited');
        expect(merchant.normalized, 'Example Foods');
      },
    );

    test('central confidence thresholds control decisions', () {
      final validator = DefaultParseValidator(
        thresholds: const ConfidenceThresholds(autoPost: 0.9, provisional: 0.6),
      );
      const amount = MonetaryCandidate(
        amountMinor: 10000,
        currency: 'INR',
        start: 0,
        end: 7,
        contextWindow: 'INR 100 paid',
        semanticRole: MonetarySemanticRole.transactionAmount,
        confidence: 0.9,
      );

      expect(
        validator
            .validate(
              relevance: FinancialRelevance.transaction,
              amount: amount,
              direction: FinancialDirection.debit,
              status: FinancialEventStatus.completed,
              overallConfidence: 0.8,
            )
            .decision,
        ParseDecision.provisional,
      );
    });

    test('handles the retained emulator notification variants', () {
      final pipeline = NotificationParsingPipeline();
      final cardPurchase = pipeline.parse(
        'iMobile',
        'Transaction of Rs 3100.00 on ICICI Bank Card XX9012 at Apple Store on 29-JUL-26',
        knownPackage: true,
      );
      final pnb = pipeline.parse(
        'PNB',
        'INR 810.00 debited from PNB A/c XX1122 at Petrol Pump. Ref: PNB11',
        knownPackage: true,
      );
      final wallet = pipeline.parse(
        'Paytm',
        'Paid Rs.160 to Tea Stall. Transaction ID: 2026072911',
        knownPackage: true,
      );
      final reversal = pipeline.parse(
        'HDFC',
        'INR 700.00 transaction at Reliance Fresh was reversed on card XX1234. Ref: TXN/290711',
        knownPackage: true,
      );

      expect(cardPurchase.direction, FinancialDirection.debit);
      expect(cardPurchase.decision, ParseDecision.autoPost);
      expect(pnb.institutionId, 'pnb');
      expect(pnb.decision, ParseDecision.autoPost);
      expect(wallet.direction, FinancialDirection.debit);
      expect(wallet.referenceNumber, '2026072911');
      expect(reversal.eventType, FinancialEventType.reversal);
      expect(reversal.status, FinancialEventStatus.reversed);
      expect(reversal.decision, ParseDecision.autoPost);
    });
  });
}
