import 'package:expense_tracker/core/models/notification_template.dart';
import 'package:expense_tracker/features/ingestion/notification_parsing_pipeline.dart';

/// A value-free shape of a notification. It is deliberately data, not a
/// pattern language: the application never evaluates learned templates.
class StructuralNotificationFingerprint {
  const StructuralNotificationFingerprint({
    required this.fingerprint,
    required this.fieldPositionMetadata,
  });

  final String fingerprint;
  final NotificationTemplateFieldMetadata fieldPositionMetadata;

  bool get canBeLearned =>
      fingerprint.length <= 2048 && fieldPositionMetadata.fields.isNotEmpty;
}

class NotificationStructuralFingerprinter {
  const NotificationStructuralFingerprinter();

  // These patterns are compile-time application code. Stored templates never
  // provide patterns and are never passed to RegExp or another evaluator.
  static final RegExp _accountPattern = RegExp(
    r'\b(?:a/c|acct|account)\s*(?:no\.?|number)?\s*[:#-]?\s*(?:[x*.\u2022\u25cf]+\s*)?\d{4,}\b',
    caseSensitive: false,
  );
  static final RegExp _cardPattern = RegExp(
    r'\b(?:credit\s+card|debit\s+card|card)\s*(?:ending(?:\s+in)?|no\.?)?\s*[:#-]?\s*(?:[x*.\u2022\u25cf]+\s*)?\d{4,}\b',
    caseSensitive: false,
  );
  static final RegExp _numericDatePattern = RegExp(
    r'\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b',
  );
  static final RegExp _namedDatePattern = RegExp(
    r'\b\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{2,4}\b',
    caseSensitive: false,
  );
  static final RegExp _timePattern = RegExp(
    r'\b\d{1,2}:\d{2}(?::\d{2})?(?:\s?[ap]m)?\b',
    caseSensitive: false,
  );
  static final RegExp _referencePattern = RegExp(
    r'\b(?:utr|rrn|ref(?:erence)?|txn\s*id|transaction\s*id|upi\s*ref)\s*[:#-]?\s*[a-z0-9]{6,30}\b',
    caseSensitive: false,
  );
  static final RegExp _vpaPattern = RegExp(
    r'\b[a-z0-9._-]{2,}@[a-z][a-z0-9.-]{1,}\b',
    caseSensitive: false,
  );

  StructuralNotificationFingerprint generate(FinancialParseResult parsed) {
    final original = parsed.normalized.originalText;
    final replacements = <_Replacement>[];

    for (final amount in parsed.amountCandidates) {
      replacements.add(
        _Replacement(
          amount.start,
          amount.end,
          NotificationTemplateFieldType.amount,
        ),
      );
    }
    _addMatches(
      replacements,
      original,
      _cardPattern,
      NotificationTemplateFieldType.card,
    );
    _addMatches(
      replacements,
      original,
      _accountPattern,
      NotificationTemplateFieldType.account,
    );
    _addMatches(
      replacements,
      original,
      _numericDatePattern,
      NotificationTemplateFieldType.date,
    );
    _addMatches(
      replacements,
      original,
      _namedDatePattern,
      NotificationTemplateFieldType.date,
    );
    _addMatches(
      replacements,
      original,
      _timePattern,
      NotificationTemplateFieldType.time,
    );
    _addMatches(
      replacements,
      original,
      _referencePattern,
      NotificationTemplateFieldType.reference,
    );
    _addMatches(
      replacements,
      original,
      _vpaPattern,
      NotificationTemplateFieldType.vpa,
    );

    final merchant = parsed.merchant.raw;
    if (merchant != null && merchant.isNotEmpty) {
      final start = original.toLowerCase().indexOf(merchant.toLowerCase());
      if (start >= 0) {
        replacements.add(
          _Replacement(
            start,
            start + merchant.length,
            NotificationTemplateFieldType.merchant,
          ),
        );
      }
    }

    replacements.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      if (byStart != 0) return byStart;
      return b.end.compareTo(a.end);
    });
    final accepted = <_Replacement>[];
    var lastEnd = -1;
    for (final replacement in replacements) {
      if (replacement.start >= lastEnd) {
        accepted.add(replacement);
        lastEnd = replacement.end;
      }
    }

    // Unusually complex input is not useful as a stable template. Keep
    // ingestion safe and simply decline to learn from it.
    if (accepted.length > 16) {
      return StructuralNotificationFingerprint(
        fingerprint: _normalizedLiteral(
          original,
        ).replaceAll(RegExp(r'\s+'), ' ').trim(),
        fieldPositionMetadata: NotificationTemplateFieldMetadata(
          fields: const [],
        ),
      );
    }

    final buffer = StringBuffer();
    var cursor = 0;
    for (final replacement in accepted) {
      buffer.write(
        _normalizedLiteral(original.substring(cursor, replacement.start)),
      );
      buffer.write(replacement.type.placeholder);
      cursor = replacement.end;
    }
    buffer.write(_normalizedLiteral(original.substring(cursor)));
    final fingerprint = buffer
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final fields = <NotificationTemplateFieldPosition>[];
    var searchOffset = 0;
    for (final replacement in accepted) {
      final placeholderOffset = fingerprint.indexOf(
        replacement.type.placeholder,
        searchOffset,
      );
      if (placeholderOffset < 0) {
        throw StateError('Generated notification placeholder was lost.');
      }
      final prefix = fingerprint.substring(0, placeholderOffset);
      final trimmedPrefix = prefix.trim();
      final precedingTokenCount = trimmedPrefix.isEmpty
          ? 0
          : trimmedPrefix.split(RegExp(r'\s+')).length;
      final sharesPrecedingToken =
          prefix.isNotEmpty && !RegExp(r'\s$').hasMatch(prefix);
      fields.add(
        NotificationTemplateFieldPosition(
          type: replacement.type,
          tokenIndex: precedingTokenCount - (sharesPrecedingToken ? 1 : 0),
        ),
      );
      searchOffset = placeholderOffset + replacement.type.placeholder.length;
    }
    return StructuralNotificationFingerprint(
      fingerprint: fingerprint,
      fieldPositionMetadata: NotificationTemplateFieldMetadata(fields: fields),
    );
  }

  String _normalizedLiteral(String value) => value
      .toLowerCase()
      // Angle-bracket placeholders can only be created by this class. Similar
      // text from a notification remains inert literal data.
      .replaceAll('<', '\u2039')
      .replaceAll('>', '\u203a');

  void _addMatches(
    List<_Replacement> output,
    String text,
    RegExp pattern,
    NotificationTemplateFieldType type,
  ) {
    for (final match in pattern.allMatches(text)) {
      output.add(_Replacement(match.start, match.end, type));
    }
  }
}

class _Replacement {
  const _Replacement(this.start, this.end, this.type);

  final int start;
  final int end;
  final NotificationTemplateFieldType type;
}
