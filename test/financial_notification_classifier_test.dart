import 'dart:convert';

import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final normalizer = DefaultNotificationNormalizer();

  test('deterministic classifier reports semantic features and version', () {
    final notification = normalizer.normalize(
      'Bank alert',
      'INR 500 debited from account XX1234 at Cafe. UTR ABC123456',
    );
    final result = const DeterministicFinancialNotificationClassifier()
        .classify(notification);
    final metadata = jsonDecode(result.metadataJson) as Map<String, Object?>;

    expect(result.relevance, FinancialRelevance.transaction);
    expect(result.confidence, greaterThanOrEqualTo(.9));
    expect(
      result.features,
      containsAll({
        FinancialNotificationSemanticFeature.transactionAction,
        FinancialNotificationSemanticFeature.debitAction,
        FinancialNotificationSemanticFeature.currencyAmount,
        FinancialNotificationSemanticFeature.accountInstrument,
        FinancialNotificationSemanticFeature.paymentReference,
      }),
    );
    expect(result.classifierId, 'deterministic_semantic');
    expect(result.classifierVersion, '1');
    expect(result.modelVersion, isNull);
    expect(metadata['classifierKind'], 'deterministic');
    expect(result.metadataJson, isNot(contains('XX1234')));
    expect(result.metadataJson, isNot(contains('ABC123456')));
  });

  test('deterministic sensitive and non-posting semantics take precedence', () {
    const classifier = DeterministicFinancialNotificationClassifier();

    expect(
      classifier
          .classify(
            normalizer.normalize(
              '',
              'OTP 123456 for INR 500 transaction. Do not share.',
            ),
          )
          .relevance,
      FinancialRelevance.otp,
    );
    expect(
      classifier
          .classify(normalizer.normalize('', 'Available balance INR 5,000.'))
          .relevance,
      FinancialRelevance.balanceOnly,
    );
  });

  test(
    'missing or failing optional classifier falls back deterministically',
    () {
      final notification = normalizer.normalize('', 'INR 100 paid at Cafe.');
      final unavailable = const ResilientFinancialNotificationClassifier(
        primary: null,
      ).classify(notification);
      final failedInference = ResilientFinancialNotificationClassifier(
        primary: _ThrowingClassifier(),
      ).classify(notification);

      for (final result in [unavailable, failedInference]) {
        expect(result.relevance, FinancialRelevance.transaction);
        expect(result.kind, FinancialNotificationClassifierKind.deterministic);
        expect(result.usedFallback, isTrue);
        expect(result.modelVersion, isNull);
      }
    },
  );

  test('optional classifier cannot override deterministic OTP safety gate', () {
    final pipeline = NotificationParsingPipeline(
      notificationClassifier: const _BundledClassifier(
        relevance: FinancialRelevance.transaction,
      ),
    );
    final result = pipeline.parse(
      'Security alert',
      'OTP 123456 for INR 500 debited transaction. Do not share.',
      knownPackage: true,
    );

    expect(result.relevance, FinancialRelevance.otp);
    expect(
      result.classification.kind,
      FinancialNotificationClassifierKind.deterministic,
    );
    expect(result.classification.usedFallback, isTrue);
    expect(result.decision, ParseDecision.ignored);
  });

  test('model-like classification still requires deterministic validation', () {
    final pipeline = NotificationParsingPipeline(
      notificationClassifier: const _BundledClassifier(
        relevance: FinancialRelevance.transaction,
      ),
    );
    final result = pipeline.parse(
      'Bank alert',
      'INR 500 debited from account XX1234 at Cafe failed.',
      knownPackage: true,
    );
    final metadata =
        jsonDecode(result.classification.metadataJson) as Map<String, Object?>;

    expect(
      result.classification.kind,
      FinancialNotificationClassifierKind.bundledModel,
    );
    expect(result.classification.modelVersion, 'fixture-model-v1');
    expect(metadata['modelVersion'], 'fixture-model-v1');
    expect(result.status, FinancialEventStatus.failed);
    expect(result.decision, ParseDecision.retainOnly);
    expect(result.failureCode, 'status_failed');
  });
}

class _ThrowingClassifier implements FinancialNotificationClassifier {
  @override
  ClassificationResult classify(NormalizedNotification notification) {
    throw StateError('simulated unavailable model');
  }
}

class _BundledClassifier implements FinancialNotificationClassifier {
  const _BundledClassifier({required this.relevance});

  final FinancialRelevance relevance;

  @override
  ClassificationResult classify(NormalizedNotification notification) {
    return ClassificationResult(
      relevance: relevance,
      confidence: .97,
      features: const {
        FinancialNotificationSemanticFeature.transactionAction,
        FinancialNotificationSemanticFeature.currencyAmount,
      },
      classifierId: 'fixture_bundled_classifier',
      classifierVersion: '1',
      kind: FinancialNotificationClassifierKind.bundledModel,
      modelVersion: 'fixture-model-v1',
    );
  }
}
