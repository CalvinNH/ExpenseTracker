import 'package:expense_tracker/features/ingestion/financial_notification_classifier.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  test('balanced qualification meets precision-first reliability thresholds', () {
    final cases = loadParserCorpus(
      'test/fixtures/parser_corpus/phase5_qualification.json',
    );
    final outcomes = parseCorpus(cases);
    final sourcePolicy = NotificationSourcePolicy(
      defaultSmsPackage: 'com.google.android.apps.messaging',
    );
    final positives = <int>[
      for (var index = 0; index < cases.length; index++)
        if (cases[index].relevant) index,
    ];
    final negatives = <int>[
      for (var index = 0; index < cases.length; index++)
        if (!cases[index].relevant) index,
    ];

    final recalled = positives.where(
      (index) =>
          outcomes[index].result.relevance == FinancialRelevance.transaction &&
          outcomes[index].result.decision != ParseDecision.ignored,
    );
    final predictedAutoPost = <int>[
      for (var index = 0; index < outcomes.length; index++)
        if (outcomes[index].result.decision == ParseDecision.autoPost) index,
    ];
    final correctAutoPost = predictedAutoPost.where(
      (index) => cases[index].relevant && cases[index].autoPostEligible,
    );
    final negativeFalsePositives = negatives.where(
      (index) =>
          outcomes[index].result.relevance == FinancialRelevance.transaction,
    );
    final unknownSourceCases = <int>[
      for (var index = 0; index < cases.length; index++)
        if (sourcePolicy.classify(cases[index].sourcePackage) ==
            NotificationSourceClass.unknownPackage)
          index,
    ];

    final financialRecall = recalled.length / positives.length;
    final autoPostPrecision =
        correctAutoPost.length / predictedAutoPost.length;
    final negativeFalsePositiveRate =
        negativeFalsePositives.length / negatives.length;
    final unknownSafeRetention = unknownSourceCases.where(
      (index) => outcomes[index].result.decision != ParseDecision.autoPost,
    ).length / unknownSourceCases.length;

    expect(positives.length, 10);
    expect(negatives.length, 10);
    expect(financialRecall, greaterThanOrEqualTo(.95));
    expect(autoPostPrecision, 1.0);
    expect(negativeFalsePositiveRate, 0.0);
    expect(unknownSafeRetention, 1.0);
    expect(
      cases.where((fixture) => fixture.autoPostEligible).every((fixture) {
        final source = sourcePolicy.classify(fixture.sourcePackage);
        return source == NotificationSourceClass.defaultSmsPackage ||
            source == NotificationSourceClass.knownFinancialPackage ||
            source == NotificationSourceClass.knownWalletPackage;
      }),
      isTrue,
    );

    final failureDistribution = <String, int>{};
    for (final outcome in outcomes) {
      final key = outcome.result.failureCode ?? 'none';
      failureDistribution[key] = (failureDistribution[key] ?? 0) + 1;
    }
    expect(failureDistribution['status_failed'], isNotNull);
    expect(failureDistribution['status_pending'], isNotNull);
    expect(failureDistribution['non_financial_or_sensitive'], isNotNull);
    expect(failureDistribution['non_posting_financial_alert'], isNotNull);
    expect(failureDistribution['transaction_amount_missing'], isNotNull);
  });
}
