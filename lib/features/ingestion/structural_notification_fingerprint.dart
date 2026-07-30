import 'dart:convert';

import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';

/// A value-free shape of a notification. It is deliberately data, not a
/// pattern language: the application never evaluates learned templates.
class StructuralNotificationFingerprint {
  const StructuralNotificationFingerprint({
    required this.fingerprint,
    required this.fieldPositionMetadata,
  });

  final String fingerprint;

  /// JSON-safe metadata containing only placeholder types and token positions.
  final Map<String, Object?> fieldPositionMetadata;

  String get metadataJson => jsonEncode(fieldPositionMetadata);
}

class NotificationStructuralFingerprinter {
  const NotificationStructuralFingerprinter();

  StructuralNotificationFingerprint generate(FinancialParseResult parsed) {
    final original = parsed.normalized.originalText;
    final replacements = <_Replacement>[];

    for (final amount in parsed.amountCandidates) {
      replacements.add(_Replacement(amount.start, amount.end, '<AMOUNT>'));
    }
    _addMatches(
      replacements,
      original,
      RegExp(r'\b(?:a/c|account)\s*(?:no\.?|number)?\s*[:#-]?\s*(?:[x*.•●]+\s*)?\d{4,}\b', caseSensitive: false),
      '<ACCOUNT>',
    );
    _addMatches(
      replacements,
      original,
      RegExp(r'\b(?:card|credit card|debit card)\s*(?:ending)?\s*[:#-]?\s*(?:[x*.•●]+\s*)?\d{4,}\b', caseSensitive: false),
      '<CARD>',
    );
    _addMatches(replacements, original, RegExp(r'\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b'), '<DATE>');
    _addMatches(replacements, original, RegExp(r'\b\d{1,2}:\d{2}(?:\s?[ap]m)?\b', caseSensitive: false), '<TIME>');
    _addMatches(
      replacements,
      original,
      RegExp(r'\b(?:utr|rrn|ref(?:erence)?|txn id|upi ref)\s*[:#-]?\s*[a-z0-9]{6,30}\b', caseSensitive: false),
      '<REFERENCE>',
    );
    _addMatches(replacements, original, RegExp(r'\b[a-z0-9._-]{2,}@[a-z][a-z0-9.-]{1,}\b', caseSensitive: false), '<VPA>');

    final merchant = parsed.merchant.raw;
    if (merchant != null && merchant.isNotEmpty) {
      final start = original.toLowerCase().indexOf(merchant.toLowerCase());
      if (start >= 0) {
        replacements.add(_Replacement(start, start + merchant.length, '<MERCHANT>'));
      }
    }

    replacements.sort((a, b) => a.start.compareTo(b.start));
    final accepted = <_Replacement>[];
    var lastEnd = -1;
    for (final replacement in replacements) {
      if (replacement.start >= lastEnd) {
        accepted.add(replacement);
        lastEnd = replacement.end;
      }
    }
    final buffer = StringBuffer();
    var cursor = 0;
    final fields = <Map<String, Object?>>[];
    for (final replacement in accepted) {
      buffer.write(original.substring(cursor, replacement.start));
      final tokenIndex = buffer.toString().trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).length;
      buffer.write(replacement.placeholder);
      fields.add({'type': replacement.placeholder, 'token': tokenIndex});
      cursor = replacement.end;
    }
    buffer.write(original.substring(cursor));
    final fingerprint = buffer
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return StructuralNotificationFingerprint(
      fingerprint: fingerprint,
      fieldPositionMetadata: {'version': 1, 'fields': fields},
    );
  }

  void _addMatches(List<_Replacement> output, String text, RegExp pattern, String placeholder) {
    for (final match in pattern.allMatches(text)) {
      output.add(_Replacement(match.start, match.end, placeholder));
    }
  }
}

class _Replacement {
  const _Replacement(this.start, this.end, this.placeholder);
  final int start;
  final int end;
  final String placeholder;
}
