import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/features/ingestion/notification_identity.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';

class NotificationEnvelope {
  const NotificationEnvelope({
    required this.packageName,
    this.notificationKey,
    this.notificationId,
    this.notificationTag,
    this.title,
    this.content,
    this.postedAt,
    required this.ingestedAt,
    this.hasRemoved = false,
  });

  final String packageName;

  /// The current plugin does not expose a stable notification key or tag, so
  /// these remain nullable. Android notification ID and posted time are used
  /// alongside the payload hash when available.
  final String? notificationKey;
  final int? notificationId;
  final String? notificationTag;

  /// The plugin exposes title and collapsed content only. Expanded text is not
  /// currently available and cannot be persisted.
  final String? title;
  final String? content;
  final DateTime? postedAt;
  final DateTime ingestedAt;
  final bool hasRemoved;
}

enum IngestionDisposition { ignored, duplicate, retained, provisional, posted }

class IngestionResult {
  const IngestionResult({
    required this.disposition,
    this.rawEventId,
    this.parsedFinancialEventId,
    this.transactionId,
    this.diagnosticCode,
  });

  final IngestionDisposition disposition;
  final int? rawEventId;
  final int? parsedFinancialEventId;
  final int? transactionId;
  final String? diagnosticCode;
}

class NotificationIngestionProcessor {
  NotificationIngestionProcessor({
    AppDatabase? database,
    NotificationSourcePolicy? sourcePolicy,
    this.parserVersion = 1,
  }) : _database = database ?? AppDatabase.instance,
       _sourcePolicy = sourcePolicy ?? NotificationSourcePolicy();

  final AppDatabase _database;
  final NotificationSourcePolicy _sourcePolicy;
  final int parserVersion;

  Future<IngestionResult> ingest(NotificationEnvelope envelope) async {
    if (envelope.hasRemoved) {
      return const IngestionResult(
        disposition: IngestionDisposition.ignored,
        diagnosticCode: 'notification_removed',
      );
    }

    final sourceClass = _sourcePolicy.classify(envelope.packageName);
    if (sourceClass == NotificationSourceClass.ignoredPackage) {
      return const IngestionResult(
        disposition: IngestionDisposition.ignored,
        diagnosticCode: 'source_explicitly_ignored',
      );
    }

    final postedAt = envelope.postedAt ?? envelope.ingestedAt;
    final rawInsert = await _database.insertRawNotificationIdempotently(
      RawNotificationEvent(
        packageName: envelope.packageName,
        notificationKey: envelope.notificationKey,
        notificationId: envelope.notificationId,
        notificationTag: envelope.notificationTag,
        title: envelope.title,
        content: envelope.content,
        postedAt: postedAt,
        ingestedAt: envelope.ingestedAt,
        payloadHash: NotificationIdentity.payloadHash(
          packageName: envelope.packageName,
          title: envelope.title,
          content: envelope.content,
        ),
        parserVersion: parserVersion,
        processingState: RawNotificationProcessingState.retained,
        structuralFingerprint: NotificationIdentity.structuralFingerprint(
          envelope.title,
          envelope.content,
        ),
      ),
    );
    final rawEvent = rawInsert.event;
    if (!rawInsert.wasInserted) {
      return IngestionResult(
        disposition: IngestionDisposition.duplicate,
        rawEventId: rawEvent.id,
        diagnosticCode: 'exact_source_duplicate',
      );
    }

    final parsed = NotificationParser.parse(
      envelope.title ?? '',
      envelope.content ?? '',
    );
    if (parsed == null) {
      final parsedId = await _database.createParsedFinancialEvent(
        ParsedFinancialEvent(
          rawNotificationEventId: rawEvent.id!,
          eventType: FinancialEventType.unknown,
          status: FinancialEventStatus.unknown,
          direction: FinancialDirection.unknown,
          overallConfidence: 0,
          parseDecision: ParseDecision.retainOnly,
          failureCode: 'parser_no_match',
        ),
      );
      await _database.updateRawNotificationProcessingState(
        rawEvent.id!,
        RawNotificationProcessingState.failed,
      );
      return IngestionResult(
        disposition: IngestionDisposition.retained,
        rawEventId: rawEvent.id,
        parsedFinancialEventId: parsedId,
        diagnosticCode: 'parser_no_match',
      );
    }

    final accounts = await _database.getAllAccounts();
    final matchedAccount = _resolveAccount(accounts, parsed, envelope);
    final unknownSourceNeedsEvidence =
        sourceClass == NotificationSourceClass.unknownPackage;
    final hasStrongEvidence = _hasStrongTextualEvidence(
      '${envelope.title ?? ''} ${envelope.content ?? ''}',
    );

    ParseDecision decision;
    String? failureCode;
    IngestionDisposition disposition;
    if (unknownSourceNeedsEvidence && !hasStrongEvidence) {
      decision = ParseDecision.retainOnly;
      failureCode = 'unknown_source_insufficient_evidence';
      disposition = IngestionDisposition.retained;
    } else if (matchedAccount == null) {
      decision = ParseDecision.provisional;
      failureCode = 'account_unresolved';
      disposition = IngestionDisposition.provisional;
    } else {
      decision = ParseDecision.autoPost;
      disposition = IngestionDisposition.posted;
    }

    if (matchedAccount != null && decision == ParseDecision.autoPost) {
      final semanticDuplicate = await _database.hasRecentDuplicate(
        amount: parsed.amount,
        type: parsed.type,
        accountId: matchedAccount.id!,
        merchant: parsed.merchant,
        referenceTime: postedAt,
        window: const Duration(minutes: 5),
      );
      if (semanticDuplicate) {
        decision = ParseDecision.retainOnly;
        failureCode = 'semantic_duplicate';
        disposition = IngestionDisposition.retained;
      }
    }

    final parsedId = await _database.createParsedFinancialEvent(
      ParsedFinancialEvent(
        rawNotificationEventId: rawEvent.id!,
        eventType: _eventTypeFor(
          '${envelope.title ?? ''} ${envelope.content ?? ''}',
        ),
        status: FinancialEventStatus.completed,
        direction: parsed.type == TransactionType.credit
            ? FinancialDirection.credit
            : FinancialDirection.debit,
        amountMinor: majorToMinor(parsed.amount),
        currencyCode: 'INR',
        merchantRaw: parsed.merchant,
        merchantNormalized: parsed.merchant.trim(),
        institutionId: parsed.bankName == 'Unknown Bank'
            ? null
            : _institutionCode(parsed.bankName),
        instrumentLastFour: parsed.cardEnding,
        transactionOccurredAt: postedAt,
        overallConfidence: sourceClass == NotificationSourceClass.unknownPackage
            ? (hasStrongEvidence ? 0.75 : 0.55)
            : 0.9,
        fieldConfidence: {
          'amount': 0.95,
          'direction': 0.9,
          'account': matchedAccount == null ? 0 : 0.9,
        },
        parseDecision: decision,
        failureCode: failureCode,
      ),
    );

    if (decision != ParseDecision.autoPost || matchedAccount == null) {
      await _database.updateRawNotificationProcessingState(
        rawEvent.id!,
        RawNotificationProcessingState.parsed,
      );
      return IngestionResult(
        disposition: disposition,
        rawEventId: rawEvent.id,
        parsedFinancialEventId: parsedId,
        diagnosticCode: failureCode,
      );
    }

    final transactionId = await _database.postIngestedTransaction(
      transaction: Transaction(
        amount: parsed.amount,
        type: parsed.type,
        timestamp: postedAt,
        merchant: parsed.merchant,
        category: parsed.category,
        accountId: matchedAccount.id!,
      ),
      parsedFinancialEventId: parsedId,
    );
    await _database.updateRawNotificationProcessingState(
      rawEvent.id!,
      RawNotificationProcessingState.posted,
    );
    return IngestionResult(
      disposition: IngestionDisposition.posted,
      rawEventId: rawEvent.id,
      parsedFinancialEventId: parsedId,
      transactionId: transactionId,
    );
  }

  Account? _resolveAccount(
    List<Account> accounts,
    ParsedNotification parsed,
    NotificationEnvelope envelope,
  ) {
    var candidates = accounts;
    if (parsed.cardEnding != null) {
      final byLastFour = candidates
          .where(
            (account) =>
                account.lastFour == parsed.cardEnding ||
                account.displayName.endsWith(parsed.cardEnding!),
          )
          .toList();
      if (byLastFour.length == 1) return byLastFour.single;
      if (byLastFour.isNotEmpty) candidates = byLastFour;
    }

    if (parsed.bankName != 'Unknown Bank') {
      final institution = _institutionCode(parsed.bankName);
      final byInstitution = candidates
          .where(
            (account) =>
                account.institutionId?.toLowerCase() == institution ||
                account.displayName.toLowerCase().contains(institution),
          )
          .toList();
      if (byInstitution.length == 1) return byInstitution.single;
      if (byInstitution.isNotEmpty) candidates = byInstitution;
    }

    final byPackage = candidates
        .where((account) => account.sourcePackageHint == envelope.packageName)
        .toList();
    if (byPackage.length == 1) return byPackage.single;
    return null;
  }

  bool _hasStrongTextualEvidence(String text) {
    final hasAmount = RegExp(
      r'(?:₹|rs\.?|inr)\s*[:\-]?\s*\d',
      caseSensitive: false,
    ).hasMatch(text);
    final hasAction = RegExp(
      r'\b(debited|credited|spent|paid|received|withdrawn|deposited|refund|cashback|transferred)\b',
      caseSensitive: false,
    ).hasMatch(text);
    final hasInstrumentOrReference = RegExp(
      r'\b(a/c|account|card|upi|vpa|ref(?:erence)?|utr|rrn|hdfc|sbi|icici|axis|kotak|bank)\b',
      caseSensitive: false,
    ).hasMatch(text);
    return hasAmount && hasAction && hasInstrumentOrReference;
  }

  FinancialEventType _eventTypeFor(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('cashback')) return FinancialEventType.cashback;
    if (lower.contains('refund')) return FinancialEventType.refund;
    if (lower.contains('reversal') || lower.contains('reversed')) {
      return FinancialEventType.reversal;
    }
    if (lower.contains('withdraw')) return FinancialEventType.withdrawal;
    if (lower.contains('deposit')) return FinancialEventType.deposit;
    if (lower.contains('transfer') || lower.contains('sent')) {
      return FinancialEventType.transfer;
    }
    return FinancialEventType.purchase;
  }

  String _institutionCode(String value) {
    final lower = value.toLowerCase();
    for (final code in [
      'hdfc',
      'sbi',
      'icici',
      'axis',
      'kotak',
      'pnb',
      'bob',
      'yes',
      'citi',
      'hsbc',
      'idfc',
      'indusind',
      'rbl',
    ]) {
      if (lower.contains(code)) return code;
    }
    return lower.split(RegExp(r'\s+')).first;
  }
}
