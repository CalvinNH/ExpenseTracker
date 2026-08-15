import 'package:expense_tracker/features/ingestion/financial_notification_classifier.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/parser_corpus.dart';

void main() {
  final cases = loadParserCorpus(
    'test/fixtures/parser_corpus/phase5_qualification.json',
  );
  final outcomes = parseCorpus(cases);
  final sourcePolicy = NotificationSourcePolicy(
    defaultSmsPackage: 'com.google.android.apps.messaging',
  );

  test('qualification corpus is category-balanced and fully specified', () {
    expect(cases, hasLength(20));
    expect(cases.where((fixture) => fixture.relevant), hasLength(10));
    expect(cases.where((fixture) => !fixture.relevant), hasLength(10));
    expect(cases.map((fixture) => fixture.category).toSet(), hasLength(20));
    expect(cases.every((fixture) => fixture.expectedDecision != null), isTrue);
    expect(cases.every((fixture) => fixture.expectedSourceClass != null), isTrue);
  });

  for (var index = 0; index < cases.length; index++) {
    final fixture = cases[index];
    final result = outcomes[index].result;
    test('phase5 qualification: ${fixture.id}', () {
      expect(
        sourcePolicy.classify(fixture.sourcePackage).name,
        fixture.expectedSourceClass,
      );
      expect(
        result.relevance == FinancialRelevance.transaction,
        fixture.relevant,
      );
      expect(
        result.direction,
        fixture.direction ?? FinancialDirection.unknown,
      );
      if (fixture.status != null) expect(result.status, fixture.status);
      if (fixture.amountMinor != null) {
        expect(result.selectedAmount?.amountMinor, fixture.amountMinor);
      }
      if (fixture.instrumentLastFour != null) {
        expect(result.instrument.lastFour, fixture.instrumentLastFour);
      }
      expect(result.decision, fixture.expectedDecision);
    });
  }
}
