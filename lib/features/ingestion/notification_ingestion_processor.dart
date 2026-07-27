import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/entity_resolution/account_resolver.dart';
import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
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
    InstitutionRegistry? institutionRegistry,
    this.parserVersion = 1,
  }) : _database = database ?? AppDatabase.instance,
       _sourcePolicy = sourcePolicy ?? NotificationSourcePolicy(),
       _institutionRegistry = institutionRegistry;

  final AppDatabase _database;
  final NotificationSourcePolicy _sourcePolicy;
  final InstitutionRegistry? _institutionRegistry;
  static Future<InstitutionRegistry>? _defaultRegistry;
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

    final parsed = NotificationParser.pipeline.parse(
      envelope.title ?? '',
      envelope.content ?? '',
      sourcePackage: envelope.packageName,
      knownPackage: sourceClass != NotificationSourceClass.unknownPackage,
    );
    if (parsed.selectedAmount == null ||
        parsed.direction == FinancialDirection.unknown) {
      final parsedId = await _database.createParsedFinancialEvent(
        ParsedFinancialEvent(
          rawNotificationEventId: rawEvent.id!,
          eventType: parsed.eventType,
          status: parsed.status,
          direction: parsed.direction,
          amountMinor: parsed.selectedAmount?.amountMinor,
          currencyCode: parsed.selectedAmount?.currency,
          merchantRaw: parsed.merchant.raw,
          merchantNormalized: parsed.merchant.normalized,
          institutionId: parsed.institutionId,
          instrumentLastFour: parsed.instrument.lastFour,
          referenceNumber: parsed.referenceNumber,
          transactionOccurredAt: parsed.transactionTime ?? postedAt,
          overallConfidence: parsed.overallConfidence,
          fieldConfidence: parsed.fieldConfidence,
          parseDecision: parsed.decision,
          failureCode: parsed.failureCode ?? 'parser_no_match',
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
        diagnosticCode: parsed.failureCode ?? 'parser_no_match',
      );
    }

    final accounts = await _database.getAllAccounts();
    final registry =
        _institutionRegistry ??
        await (_defaultRegistry ??= InstitutionRegistry.load());
    final resolution = AccountResolver(registry).resolve(
      accounts,
      AccountResolutionEvidence(
        institution: parsed.institutionId,
        instrumentLastFour: parsed.instrument.lastFour,
        sourcePackage: envelope.packageName,
        rawText: '${envelope.title ?? ''} ${envelope.content ?? ''}',
      ),
    );
    Account? matchedAccount = resolution.resolvedAccountId == null
        ? null
        : accounts
              .where((account) => account.id == resolution.resolvedAccountId)
              .firstOrNull;
    final unknownSourceNeedsEvidence =
        sourceClass == NotificationSourceClass.unknownPackage;
    final hasStrongEvidence =
        _hasStrongTextualEvidence(
          '${envelope.title ?? ''} ${envelope.content ?? ''}',
        ) ||
        (resolution.resolutionStatus ==
                ResolutionStatus.newInstrumentCandidate &&
            resolution.confidence >= .8);
    if (matchedAccount == null &&
        resolution.resolutionStatus ==
            ResolutionStatus.newInstrumentCandidate &&
        hasStrongEvidence) {
      final record =
          registry.byId(parsed.institutionId) ??
          registry.institutions
              .where(
                (candidate) =>
                    [candidate.canonicalName, ...candidate.aliases].any(
                      (alias) =>
                          ('${envelope.title ?? ''} ${envelope.content ?? ''}')
                              .toLowerCase()
                              .contains(alias.toLowerCase()),
                    ),
              )
              .firstOrNull;
      if (record != null &&
          record.institutionType != InstitutionType.paymentApplication &&
          record.institutionType != InstitutionType.merchantPlatform) {
        final suffix = parsed.instrument.lastFour;
        final displayName = record.institutionType == InstitutionType.wallet
            ? record.canonicalName
            : suffix == null
            ? record.canonicalName
            : '${record.canonicalName} account ending $suffix';
        final newId = await _database.createAccount(
          Account(
            displayName: displayName,
            institutionId: record.institutionId,
            accountType: record.institutionType == InstitutionType.wallet
                ? AccountType.wallet
                : AccountType.bankAccount,
            lastFour: suffix,
            sourcePackageHint: envelope.packageName,
            isProvisional: true,
          ),
        );
        matchedAccount = (await _database.getAccount(newId))!;
      }
    }

    var decision = parsed.decision;
    var failureCode = parsed.failureCode;
    IngestionDisposition disposition;
    if (decision == ParseDecision.ignored) {
      disposition = IngestionDisposition.retained;
    } else if (decision == ParseDecision.retainOnly) {
      disposition = IngestionDisposition.retained;
    } else if (unknownSourceNeedsEvidence && !hasStrongEvidence) {
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
        amount: minorToMajor(parsed.selectedAmount!.amountMinor),
        type: parsed.direction == FinancialDirection.credit
            ? TransactionType.credit
            : TransactionType.debit,
        accountId: matchedAccount.id!,
        merchant: parsed.merchant.normalized,
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
        eventType: parsed.eventType,
        status: parsed.status,
        direction: parsed.direction,
        amountMinor: parsed.selectedAmount!.amountMinor,
        currencyCode: parsed.selectedAmount!.currency,
        merchantRaw: parsed.merchant.raw,
        merchantNormalized: parsed.merchant.normalized,
        institutionId: parsed.institutionId,
        instrumentLastFour: parsed.instrument.lastFour,
        referenceNumber: parsed.referenceNumber,
        transactionOccurredAt: parsed.transactionTime ?? postedAt,
        overallConfidence: parsed.overallConfidence,
        fieldConfidence: {
          ...parsed.fieldConfidence,
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
        amount: minorToMajor(parsed.selectedAmount!.amountMinor),
        type: parsed.direction == FinancialDirection.credit
            ? TransactionType.credit
            : TransactionType.debit,
        timestamp: parsed.transactionTime ?? postedAt,
        merchant: parsed.merchant.raw ?? 'Unknown',
        category: NotificationParser.categorizeMerchant(
          parsed.merchant.normalized ?? '',
        ),
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
}
