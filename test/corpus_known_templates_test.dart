import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/financial_notification_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  final cases = loadParserCorpus(
    'test/fixtures/parser_corpus/known_templates.json',
  );
  final outcomes = parseCorpus(cases);

  for (var index = 0; index < cases.length; index++) {
    final fixture = cases[index];
    final result = outcomes[index].result;
    test('known template: ${fixture.id}', () {
      expect(
        result.relevance == FinancialRelevance.transaction,
        fixture.relevant,
      );
      if (fixture.direction != null) {
        expect(result.direction, fixture.direction);
      }
      if (fixture.status != null) expect(result.status, fixture.status);
      if (fixture.amountMinor != null) {
        expect(result.selectedAmount?.amountMinor, fixture.amountMinor);
      }
      if (fixture.instrumentLastFour != null) {
        expect(result.instrument.lastFour, fixture.instrumentLastFour);
      }
      if (fixture.autoPostEligible) {
        expect(result.decision, ParseDecision.autoPost);
      } else {
        expect(result.decision, isNot(ParseDecision.autoPost));
      }
    });
  }
}
