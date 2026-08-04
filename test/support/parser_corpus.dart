import 'dart:convert';
import 'dart:io';

import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';

class ParserCorpusCase {
  const ParserCorpusCase({
    required this.id,
    required this.sourcePackage,
    required this.title,
    required this.content,
    required this.relevant,
    this.direction,
    this.status,
    this.amountMinor,
    this.instrumentLastFour,
    required this.autoPostEligible,
  });

  final String id;
  final String sourcePackage;
  final String title;
  final String content;
  final bool relevant;
  final FinancialDirection? direction;
  final FinancialEventStatus? status;
  final int? amountMinor;
  final String? instrumentLastFour;
  final bool autoPostEligible;

  factory ParserCorpusCase.fromJson(Map<String, Object?> json) =>
      ParserCorpusCase(
        id: json['id']! as String,
        sourcePackage: json['sourcePackage']! as String,
        title: json['title']! as String,
        content: json['content']! as String,
        relevant: json['relevant']! as bool,
        direction: json['direction'] == null
            ? null
            : FinancialDirection.fromStorage(json['direction']! as String),
        status: json['status'] == null
            ? null
            : FinancialEventStatus.fromStorage(json['status']! as String),
        amountMinor: json['amountMinor'] as int?,
        instrumentLastFour: json['instrumentLastFour'] as String?,
        autoPostEligible: json['autoPostEligible']! as bool,
      );
}

List<ParserCorpusCase> loadParserCorpus(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as List;
  return decoded
      .cast<Map<String, Object?>>()
      .map(ParserCorpusCase.fromJson)
      .toList(growable: false);
}

class ParserCorpusOutcome {
  const ParserCorpusOutcome({required this.result, this.isDuplicate = false});

  final FinancialParseResult result;
  final bool isDuplicate;
}

class ParserQualityMetrics {
  const ParserQualityMetrics({
    required this.transactionRelevancePrecision,
    required this.transactionRelevanceRecall,
    required this.directionAccuracy,
    required this.statusAccuracy,
    required this.amountAccuracy,
    required this.instrumentResolutionAccuracy,
    required this.autoPostPrecision,
    required this.duplicateRate,
    required this.unresolvedRate,
  });

  final double transactionRelevancePrecision;
  final double transactionRelevanceRecall;
  final double directionAccuracy;
  final double statusAccuracy;
  final double amountAccuracy;
  final double instrumentResolutionAccuracy;
  final double autoPostPrecision;
  final double duplicateRate;
  final double unresolvedRate;

  static ParserQualityMetrics calculate(
    List<ParserCorpusCase> cases,
    List<ParserCorpusOutcome> outcomes,
  ) {
    if (cases.length != outcomes.length) {
      throw ArgumentError('Corpus and outcome lengths must match.');
    }
    var truePositive = 0;
    var falsePositive = 0;
    var falseNegative = 0;
    var relevantCount = 0;
    var directionTotal = 0;
    var directionCorrect = 0;
    var statusTotal = 0;
    var statusCorrect = 0;
    var amountTotal = 0;
    var amountCorrect = 0;
    var instrumentTotal = 0;
    var instrumentCorrect = 0;
    var autoPostCount = 0;
    var correctAutoPostCount = 0;
    var duplicateCount = 0;
    var unresolvedCount = 0;

    for (var index = 0; index < cases.length; index++) {
      final fixture = cases[index];
      final outcome = outcomes[index];
      final result = outcome.result;
      final predictedRelevant =
          result.relevance == FinancialRelevance.transaction;
      if (fixture.relevant && predictedRelevant) truePositive++;
      if (!fixture.relevant && predictedRelevant) falsePositive++;
      if (fixture.relevant && !predictedRelevant) falseNegative++;
      if (fixture.relevant) {
        relevantCount++;
        if (result.decision != ParseDecision.autoPost) unresolvedCount++;
      }
      if (fixture.relevant && fixture.direction != null) {
        directionTotal++;
        if (result.direction == fixture.direction) directionCorrect++;
      }
      if (fixture.relevant && fixture.status != null) {
        statusTotal++;
        if (result.status == fixture.status) statusCorrect++;
      }
      if (fixture.relevant && fixture.amountMinor != null) {
        amountTotal++;
        if (result.selectedAmount?.amountMinor == fixture.amountMinor) {
          amountCorrect++;
        }
      }
      if (fixture.relevant && fixture.instrumentLastFour != null) {
        instrumentTotal++;
        if (result.instrument.lastFour == fixture.instrumentLastFour) {
          instrumentCorrect++;
        }
      }
      if (result.decision == ParseDecision.autoPost) {
        autoPostCount++;
        final coreFieldsMatch =
            fixture.relevant &&
            fixture.autoPostEligible &&
            (fixture.direction == null ||
                result.direction == fixture.direction) &&
            (fixture.status == null || result.status == fixture.status) &&
            (fixture.amountMinor == null ||
                result.selectedAmount?.amountMinor == fixture.amountMinor) &&
            (fixture.instrumentLastFour == null ||
                result.instrument.lastFour == fixture.instrumentLastFour);
        if (coreFieldsMatch) correctAutoPostCount++;
      }
      if (outcome.isDuplicate) duplicateCount++;
    }

    double ratio(int numerator, int denominator) =>
        denominator == 0 ? 1 : numerator / denominator;
    return ParserQualityMetrics(
      transactionRelevancePrecision: ratio(
        truePositive,
        truePositive + falsePositive,
      ),
      transactionRelevanceRecall: ratio(
        truePositive,
        truePositive + falseNegative,
      ),
      directionAccuracy: ratio(directionCorrect, directionTotal),
      statusAccuracy: ratio(statusCorrect, statusTotal),
      amountAccuracy: ratio(amountCorrect, amountTotal),
      instrumentResolutionAccuracy: ratio(instrumentCorrect, instrumentTotal),
      autoPostPrecision: ratio(correctAutoPostCount, autoPostCount),
      duplicateRate: ratio(duplicateCount, cases.length),
      unresolvedRate: ratio(unresolvedCount, relevantCount),
    );
  }
}

List<ParserCorpusOutcome> parseCorpus(List<ParserCorpusCase> cases) {
  final pipeline = NotificationParsingPipeline();
  return cases
      .map(
        (fixture) => ParserCorpusOutcome(
          result: pipeline.parse(
            fixture.title,
            fixture.content,
            sourcePackage: fixture.sourcePackage,
            knownPackage: true,
          ),
        ),
      )
      .toList(growable: false);
}
