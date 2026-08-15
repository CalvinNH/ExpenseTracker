import 'dart:convert';

/// Local parser telemetry stored only in the encrypted database and bounded by
/// retention. [structuralFingerprint] is content-derived diagnostic evidence;
/// it must never leave the database. [toExportMap] exposes only coarse,
/// application-defined buckets.
class ParserDiagnostic {
  const ParserDiagnostic({
    this.id,
    required this.observedAt,
    required this.parserVersion,
    required this.extractorsUsed,
    required this.decision,
    required this.confidence,
    this.failureCode,
    required this.sourceCategory,
    required this.structuralFingerprint,
  });

  final int? id;
  final DateTime observedAt;
  final int parserVersion;
  final List<String> extractorsUsed;
  final String decision;
  final double confidence;
  final String? failureCode;
  final String sourceCategory;
  final String structuralFingerprint;

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'observed_at': observedAt.toUtc().toIso8601String(),
    'parser_version': parserVersion,
    'extractors_used': jsonEncode(extractorsUsed),
    'decision': decision,
    'confidence': confidence,
    'failure_code': failureCode,
    'source_category': sourceCategory,
    'structural_fingerprint': structuralFingerprint,
  };

  factory ParserDiagnostic.fromMap(Map<String, Object?> map) {
    final decoded = jsonDecode(map['extractors_used']! as String) as List;
    return ParserDiagnostic(
      id: map['id'] as int?,
      observedAt: DateTime.parse(map['observed_at']! as String),
      parserVersion: map['parser_version']! as int,
      extractorsUsed: decoded.cast<String>(),
      decision: map['decision']! as String,
      confidence: (map['confidence']! as num).toDouble(),
      failureCode: map['failure_code'] as String?,
      sourceCategory: map['source_category']! as String,
      structuralFingerprint: map['structural_fingerprint']! as String,
    );
  }

  Map<String, Object?> toExportMap() => {
    // Never export content-derived fingerprints or extractor strings: even a
    // redacted/hash-shaped value can be matched against a notification corpus.
    'observedDay': _observedDay,
    'parserVersion': parserVersion,
    'decision': _allowedDecisions.contains(decision) ? decision : 'unknown',
    'confidenceBand': switch (confidence) {
      < .25 => 'none',
      < .60 => 'low',
      < .85 => 'medium',
      _ => 'high',
    },
    'failureCategory': _failureCategory(failureCode),
    'sourceCategory': _allowedSourceCategories.contains(sourceCategory)
        ? sourceCategory
        : 'unknownPackage',
  };

  String get _observedDay {
    final utc = observedAt.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  static const _allowedDecisions = <String>{
    'autoPost',
    'provisional',
    'retainOnly',
    'ignored',
  };

  static const _allowedSourceCategories = <String>{
    'defaultSmsPackage',
    'knownNonDefaultSmsPackage',
    'knownFinancialPackage',
    'knownWalletPackage',
    'knownMerchantPackage',
    'bestEffortEmailPackage',
    'ignoredPackage',
    'unknownPackage',
  };

  static String? _failureCategory(String? code) {
    if (code == null) return null;
    if (code.startsWith('status_')) return 'status';
    return switch (code) {
      'transaction_amount_missing' => 'amountMissing',
      'direction_unresolved' => 'directionUnresolved',
      'confidence_low' || 'confidence_provisional' => 'confidence',
      'non_financial_or_sensitive' => 'nonFinancial',
      'non_posting_financial_alert' => 'nonPosting',
      'account_confirmation_required' || 'account_unresolved' => 'account',
      'secondary_source_review_required' => 'secondarySource',
      'unknown_source_insufficient_evidence' => 'sourceEvidence',
      'updated_notification_financial_conflict' => 'updateConflict',
      _ => 'other',
    };
  }
}
