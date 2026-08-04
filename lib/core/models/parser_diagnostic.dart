import 'dart:convert';

/// Value-free parser telemetry stored only in the encrypted local database.
/// Raw notification text and extracted financial values are intentionally not
/// representable by this model.
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
    'observedAt': observedAt.toUtc().toIso8601String(),
    'parserVersion': parserVersion,
    'extractorsUsed': extractorsUsed,
    'decision': decision,
    'confidence': confidence,
    'failureCode': failureCode,
    'sourceCategory': sourceCategory,
    'structuralFingerprint': ParserDiagnosticRedactor.redactFingerprint(
      structuralFingerprint,
    ),
  };
}

class ParserDiagnosticRedactor {
  const ParserDiagnosticRedactor._();

  static String redactFingerprint(String input) {
    var output = input;
    output = output.replaceAll(
      RegExp(
        r'(?:₹|\binr\b|\brs\.?\b)\s*[:\-]?\s*[0-9][0-9,]*(?:\.[0-9]{1,2})?',
        caseSensitive: false,
      ),
      '<AMOUNT>',
    );
    output = output.replaceAll(
      RegExp(
        r'\b(?:a/c|acct|account|card)\s*(?:no\.?|number|ending(?:\s+in)?)?\s*[:#-]?\s*(?:[x*.•●]+\s*)?\d{3,}\b',
        caseSensitive: false,
      ),
      '<ACCOUNT>',
    );
    output = output.replaceAll(
      RegExp(r'\b(?:x{2,}|\*{2,})\d{3,6}\b', caseSensitive: false),
      '<ACCOUNT>',
    );
    // VPA must be redacted before a trailing "UPI Ref" label can be
    // interpreted as a reference field.
    output = output.replaceAll(
      RegExp(r'\b[a-z0-9._-]{2,}@[a-z][a-z0-9.-]{1,}\b', caseSensitive: false),
      '<VPA>',
    );
    output = output.replaceAll(
      RegExp(
        r'\b(?:utr|rrn|ref(?:erence)?|txn\s*id|transaction\s*id|upi\s*ref)\s*[:#-]?\s*[a-z0-9]{4,30}\b',
        caseSensitive: false,
      ),
      '<REFERENCE>',
    );
    // A defensive fallback for fingerprints produced when merchant extraction
    // was incomplete. It only redacts bounded merchant-position phrases.
    output = output.replaceAllMapped(
      RegExp(
        r'\b(at|merchant)\s+([a-z0-9][a-z0-9 &._-]{1,60}?)(?=\s+(?:on|dated|ref|utr|rrn|using|via|from|$))',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)} <MERCHANT>',
    );
    return output.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
