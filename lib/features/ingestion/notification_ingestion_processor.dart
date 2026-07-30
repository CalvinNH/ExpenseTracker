import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/entity_resolution/account_resolver.dart';
import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
import 'package:expense_tracker/core/entity_resolution/related_financial_event_linker.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';
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

enum IngestionDisposition {
  ignored,
  sourceDuplicate,
  ledgerDuplicate,
  retained,
  provisional,
  posted,
}

class IngestionResult {
  const IngestionResult({
    required this.disposition,
    this.rawEventId,
    this.parsedFinancialEventId,
    this.transactionId,
    this.diagnosticCode,
    this.duplicateConfidence = 0,
    this.matchedLedgerEntryId,
  });

  final IngestionDisposition disposition;
  final int? rawEventId;
  final int? parsedFinancialEventId;
  final int? transactionId;
  final String? diagnosticCode;
  final double duplicateConfidence;
  final int? matchedLedgerEntryId;
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
            : Account.formatDisplayName(record.canonicalName, suffix);
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
    final paymentRail = _inferPaymentRail(
      '${envelope.title ?? ''} ${envelope.content ?? ''}',
    );
    final transactionCategory = NotificationParser.categorizeMerchant(
      parsed.merchant.normalized ?? '',
    );
    var duplicateAssessment = const DuplicateAssessment.none();
    var sourceDuplicate = false;
    IngestionDisposition disposition;
    if (decision == ParseDecision.ignored) {
      disposition = IngestionDisposition.retained;
    } else if (decision == ParseDecision.retainOnly) {
      disposition = IngestionDisposition.retained;
    } else if ((parsed.eventType == FinancialEventType.refund ||
            parsed.eventType == FinancialEventType.reversal) &&
        parsed.status != FinancialEventStatus.completed) {
      decision = ParseDecision.retainOnly;
      failureCode = null;
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
      final exactSourceLedgerId = rawEvent.exactDuplicateOfEventId == null
          ? null
          : await _database.getLedgerEntryIdForRawEvent(
              rawEvent.exactDuplicateOfEventId!,
            );
      if (exactSourceLedgerId != null) {
        sourceDuplicate = true;
        duplicateAssessment = DuplicateAssessment(
          confidence: 1,
          rationales: const [MatchRationale.payloadHash],
          matchedId: exactSourceLedgerId,
        );
      } else {
        final fingerprint = FinancialEventFingerprint(
          amountMinor: parsed.selectedAmount!.amountMinor,
          currencyCode: parsed.selectedAmount!.currency,
          direction: parsed.direction.storageValue,
          accountId: matchedAccount.id!,
          merchant: parsed.merchant.normalized,
          reference: parsed.referenceNumber,
          paymentRail: paymentRail,
          occurredAt: parsed.transactionTime ?? postedAt,
          sourcePackage: envelope.packageName,
        );
        duplicateAssessment = const LedgerDuplicateDetector().assess(
          fingerprint,
          await _database.getLedgerMatchCandidates(
            accountId: matchedAccount.id!,
            occurredAt: parsed.transactionTime ?? postedAt,
          ),
        );
      }
      if (duplicateAssessment.isDefinitive) {
        decision = ParseDecision.retainOnly;
        failureCode = null;
        disposition = sourceDuplicate
            ? IngestionDisposition.sourceDuplicate
            : IngestionDisposition.ledgerDuplicate;
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
        paymentRail: paymentRail,
        transactionOccurredAt: parsed.transactionTime ?? postedAt,
        overallConfidence: parsed.overallConfidence,
        fieldConfidence: {
          ...parsed.fieldConfidence,
          'account': matchedAccount == null ? 0 : 0.9,
        },
        parseDecision: decision,
        failureCode: failureCode,
        ledgerDuplicateConfidence: duplicateAssessment.confidence,
        ledgerDuplicateRationale: duplicateAssessment.rationales
            .map((rationale) => rationale.storageValue)
            .join(','),
      ),
    );

    if (duplicateAssessment.isDefinitive) {
      await _database.linkParsedEventToLedger(
        parsedFinancialEventId: parsedId,
        ledgerEntryId: duplicateAssessment.matchedId!,
        assessment: duplicateAssessment,
      );
      await _linkRelatedEvent(
        parsedFinancialEventId: parsedId,
        eventType: parsed.eventType,
        status: parsed.status,
        direction: parsed.direction,
        accountId: matchedAccount!.id!,
        amountMinor: parsed.selectedAmount!.amountMinor,
        merchant: parsed.merchant.normalized,
        category: transactionCategory,
        reference: parsed.referenceNumber,
        occurredAt: parsed.transactionTime ?? postedAt,
        sourcePackage: envelope.packageName,
      );
      await _database.updateRawNotificationProcessingState(
        rawEvent.id!,
        RawNotificationProcessingState.parsed,
      );
      return IngestionResult(
        disposition: disposition,
        rawEventId: rawEvent.id,
        parsedFinancialEventId: parsedId,
        diagnosticCode: sourceDuplicate
            ? 'exact_source_duplicate'
            : 'probable_ledger_duplicate',
        duplicateConfidence: duplicateAssessment.confidence,
        matchedLedgerEntryId: duplicateAssessment.matchedId,
      );
    }

    if (decision != ParseDecision.autoPost || matchedAccount == null) {
      if (matchedAccount != null &&
          (parsed.eventType == FinancialEventType.refund ||
              parsed.eventType == FinancialEventType.reversal) &&
          parsed.status != FinancialEventStatus.completed) {
        await _linkRelatedEvent(
          parsedFinancialEventId: parsedId,
          eventType: parsed.eventType,
          status: parsed.status,
          direction: parsed.direction,
          accountId: matchedAccount.id!,
          amountMinor: parsed.selectedAmount!.amountMinor,
          merchant: parsed.merchant.normalized,
          category: transactionCategory,
          reference: parsed.referenceNumber,
          occurredAt: parsed.transactionTime ?? postedAt,
          sourcePackage: envelope.packageName,
        );
      }
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
        category: transactionCategory,
        accountId: matchedAccount.id!,
      ),
      parsedFinancialEventId: parsedId,
    );
    await _linkRelatedEvent(
      parsedFinancialEventId: parsedId,
      eventType: parsed.eventType,
      status: parsed.status,
      direction: parsed.direction,
      accountId: matchedAccount.id!,
      amountMinor: parsed.selectedAmount!.amountMinor,
      merchant: parsed.merchant.normalized,
      category: transactionCategory,
      reference: parsed.referenceNumber,
      occurredAt: parsed.transactionTime ?? postedAt,
      sourcePackage: envelope.packageName,
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

  String? _inferPaymentRail(String text) {
    final normalized = text.toLowerCase();
    if (RegExp(r'\bupi\b').hasMatch(normalized)) return 'upi';
    if (RegExp(r'\b(?:imps|neft|rtgs)\b').hasMatch(normalized)) {
      return RegExp(r'\b(?:imps|neft|rtgs)\b').firstMatch(normalized)?.group(0);
    }
    if (RegExp(r'\bcard\b').hasMatch(normalized)) return 'card';
    if (RegExp(r'\bwallet\b').hasMatch(normalized)) return 'wallet';
    return null;
  }

  Future<void> _linkRelatedEvent({
    required int parsedFinancialEventId,
    required FinancialEventType eventType,
    required FinancialEventStatus status,
    required FinancialDirection direction,
    required int accountId,
    required int amountMinor,
    required String? merchant,
    required String category,
    required String? reference,
    required DateTime occurredAt,
    required String sourcePackage,
  }) async {
    final incoming = RelatedFinancialEvent(
      eventType: eventType,
      direction: direction,
      accountId: accountId,
      amountMinor: amountMinor,
      merchant: merchant,
      transactionReference: reference,
      refundOrOrderReference: reference,
      occurredAt: occurredAt,
      sourcePackage: sourcePackage,
    );
    final candidateRows = await _database.getRelatedGroupCandidates(
      accountId:
          eventType == FinancialEventType.refund ||
              eventType == FinancialEventType.reversal ||
              eventType == FinancialEventType.cashback
          ? null
          : accountId,
    );
    final candidates = candidateRows.map((row) {
      return RelatedEventCandidate(
        transactionGroupId: row['transaction_group_id'] as int,
        anchor: RelatedFinancialEvent(
          eventType: FinancialEventType.fromStorage(
            row['event_type'] as String,
          ),
          direction: FinancialDirection.fromStorage(row['direction'] as String),
          accountId: row['account_id'] as int? ?? accountId,
          amountMinor: row['amount_minor'] as int,
          merchant: row['merchant_normalized'] as String?,
          transactionReference: row['reference_number'] as String?,
          refundOrOrderReference: row['reference_number'] as String?,
          occurredAt: DateTime.parse(row['transaction_occurred_at'] as String),
          sourcePackage: row['package_name'] as String,
        ),
      );
    }).toList();
    final assessment = const RelatedFinancialEventLinker().link(
      incoming,
      candidates,
    );

    int groupId;
    if (assessment.matchedId != null && !assessment.ambiguous) {
      groupId = assessment.matchedId!;
      if (status == FinancialEventStatus.completed) {
        final group = await _database.getTransactionGroup(groupId);
        if (group != null &&
            eventType == FinancialEventType.refund &&
            group.originalAmountMinor != null) {
          final completed = group.completedRefundAmountMinor + amountMinor;
          final refundable =
              group.refundableAmountMinor ?? group.originalAmountMinor!;
          final excess = completed > refundable;
          await _database.updateTransactionGroupLifecycle(
            transactionGroupId: groupId,
            groupType: completed == refundable
                ? TransactionGroupType.purchaseRefund
                : TransactionGroupType.partialRefund,
            completedRefundAmountMinor: completed,
            netExpenseMinor: group.originalAmountMinor! - completed,
            isInconsistent: group.isInconsistent || excess,
            inconsistencyReason: excess
                ? 'completed_refund_exceeds_refundable_amount'
                : group.inconsistencyReason,
          );
          if (assessment.confidence >= .85) {
            final refundCategory = group.category?.toLowerCase() == 'salary'
                ? null
                : group.category;
            await _database.updateLedgerCategoryForParsedEvent(
              parsedFinancialEventId,
              refundCategory,
            );
          }
        } else if (group != null && eventType == FinancialEventType.reversal) {
          await _database.updateTransactionGroupLifecycle(
            transactionGroupId: groupId,
            groupType: TransactionGroupType.reversal,
            completedRefundAmountMinor: group.completedRefundAmountMinor,
            netExpenseMinor: 0,
            isInconsistent: group.isInconsistent,
            inconsistencyReason: group.inconsistencyReason,
          );
        } else {
          await _database.updateTransactionGroupType(
            groupId,
            transactionGroupTypeFor(
              eventType: eventType,
              hasOriginalPurchase: true,
            ),
          );
        }
      }
      await _database.linkParsedEventToGroup(
        parsedFinancialEventId: parsedFinancialEventId,
        transactionGroupId: groupId,
        assessment: assessment,
      );
      return;
    }

    final now = DateTime.now().toUtc();
    groupId = await _database.createTransactionGroup(
      TransactionGroup(
        groupType: transactionGroupTypeFor(
          eventType: eventType,
          hasOriginalPurchase: false,
        ),
        merchantNormalized: merchant,
        category:
            eventType == FinancialEventType.refund &&
                category.toLowerCase() == 'salary'
            ? null
            : category,
        originalAmountMinor: direction == FinancialDirection.debit
            ? amountMinor
            : null,
        refundableAmountMinor: direction == FinancialDirection.debit
            ? amountMinor
            : null,
        completedRefundAmountMinor:
            eventType == FinancialEventType.refund &&
                status == FinancialEventStatus.completed
            ? amountMinor
            : 0,
        netExpenseMinor: status != FinancialEventStatus.completed
            ? 0
            : direction == FinancialDirection.debit
            ? amountMinor
            : -amountMinor,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await _database.linkParsedEventToGroup(
      parsedFinancialEventId: parsedFinancialEventId,
      transactionGroupId: groupId,
      assessment: const DuplicateAssessment(
        confidence: 1,
        rationales: [MatchRationale.compatibleEventSequence],
      ),
    );
  }
}
