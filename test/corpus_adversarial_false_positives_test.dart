import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/financial_notification_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  final cases = loadParserCorpus(
    'test/fixtures/parser_corpus/adversarial_false_positives.json',
  );
  final outcomes = parseCorpus(cases);

  for (var index = 0; index < cases.length; index++) {
    final fixture = cases[index];
    final result = outcomes[index].result;
    test('adversarial false positive: ${fixture.id}', () {
      if (!fixture.relevant) {
        expect(result.relevance, isNot(FinancialRelevance.transaction));
      }
      if (fixture.direction != null) {
        expect(result.direction, fixture.direction);
      }
      if (fixture.status != null) {
        expect(result.status, fixture.status);
      }
      expect(
        result.decision,
        isNot(ParseDecision.autoPost),
        reason:
            'uncertain, failed, pending, and non-transaction alerts stay out',
      );
    });
  }
}
