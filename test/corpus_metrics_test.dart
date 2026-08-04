import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  test('corpus metrics prioritize auto-post precision over recall', () {
    final cases = <ParserCorpusCase>[
      ...loadParserCorpus('test/fixtures/parser_corpus/known_templates.json'),
      ...loadParserCorpus('test/fixtures/parser_corpus/unseen_wording.json'),
      ...loadParserCorpus(
        'test/fixtures/parser_corpus/institution_holdout.json',
      ),
      ...loadParserCorpus(
        'test/fixtures/parser_corpus/adversarial_false_positives.json',
      ),
    ];
    final metrics = ParserQualityMetrics.calculate(cases, parseCorpus(cases));

    expect(metrics.transactionRelevancePrecision, greaterThanOrEqualTo(.97));
    expect(metrics.transactionRelevanceRecall, greaterThanOrEqualTo(.90));
    expect(metrics.directionAccuracy, greaterThanOrEqualTo(.95));
    expect(metrics.statusAccuracy, greaterThanOrEqualTo(.95));
    expect(metrics.amountAccuracy, greaterThanOrEqualTo(.95));
    expect(metrics.instrumentResolutionAccuracy, greaterThanOrEqualTo(.95));
    expect(metrics.autoPostPrecision, 1.0);
    expect(
      metrics.autoPostPrecision,
      greaterThanOrEqualTo(metrics.transactionRelevanceRecall),
    );
    expect(metrics.duplicateRate, 0);
    expect(metrics.unresolvedRate, greaterThan(0));
  });
}
