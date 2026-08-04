import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/financial_notification_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  final cases = loadParserCorpus(
    'test/fixtures/parser_corpus/institution_holdout.json',
  );
  final outcomes = parseCorpus(cases);
  const expectedInstitution = <String, String>{
    'pnb': 'pnb',
    'bob': 'bob',
    'canara': 'canara',
    'union': 'union',
    'idfc': 'idfc',
    'yes': 'yes',
    'indusind': 'indusind',
  };

  for (var index = 0; index < cases.length; index++) {
    final fixture = cases[index];
    final result = outcomes[index].result;
    test('institution holdout: ${fixture.id}', () {
      expect(result.relevance, FinancialRelevance.transaction);
      expect(result.direction, fixture.direction);
      expect(result.status, FinancialEventStatus.completed);
      expect(result.selectedAmount?.amountMinor, fixture.amountMinor);
      expect(result.instrument.lastFour, fixture.instrumentLastFour);
      expect(result.institutionId, expectedInstitution[fixture.id]);
      expect(result.decision, ParseDecision.autoPost);
    });
  }
}
