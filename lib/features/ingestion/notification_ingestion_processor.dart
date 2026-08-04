import 'package:expense_tracker/core/database/app_database.dart';
import 'package:expense_tracker/core/entity_resolution/account_resolver.dart';
import 'package:expense_tracker/core/entity_resolution/institution_registry.dart';
import 'package:expense_tracker/core/entity_resolution/related_financial_event_linker.dart';
import 'package:expense_tracker/core/models/account.dart';
import 'package:expense_tracker/core/models/event_matching.dart';
import 'package:expense_tracker/core/models/financial_enums.dart';
import 'package:expense_tracker/core/models/money.dart';
import 'package:expense_tracker/core/models/parser_diagnostic.dart';
import 'package:expense_tracker/core/models/parsed_financial_event.dart';
import 'package:expense_tracker/core/models/raw_notification_event.dart';
import 'package:expense_tracker/core/models/transaction.dart';
import 'package:expense_tracker/core/models/transaction_group.dart';
import 'package:expense_tracker/features/ingestion/notification_identity.dart';
import 'package:expense_tracker/features/ingestion/notification_parser.dart';
import 'package:expense_tracker/features/ingestion/notification_source_policy.dart';
import 'package:expense_tracker/features/ingestion/structural_notification_fingerprint.dart';

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

class _RelatedEventLink {
  const _RelatedEventLink({
    required this.transactionGroupId,
    required this.ledgerCategory,
  });

  final int transactionGroupId;
  final String? ledgerCategory;
}

class NotificationIngestionProcessor {
  NotificationIngestionProcessor({
    AppDatabase? database,
    NotificationSourcePolicy? sourcePolicy,
    NotificationParsingPipeline? parsingPipeline,
    this.institutionRegistry,
    this.parserVersion = 2,
  }) : _database = database ?? AppDatabase.instance,
       _sourcePolicy = sourcePolicy ?? NotificationSourcePolicy(),
       _parsingPipeline = parsingPipeline ?? NotificationParser.pipeline;

  final AppDatabase _database;
  final NotificationSourcePolicy _sourcePolicy;
  final NotificationParsingPipeline _parsingPipeline;
  final InstitutionRegistry? institutionRegistry;
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
    final parsed = _parsingPipeline.parse(
      envelope.title ?? '',
      envelope.content ?? '',
      sourcePackage: envelope.packageName,
      knownPackage: sourceClass != NotificationSourceClass.unknownPackage,
    );
    final structuralTemplate = const NotificationStructuralFingerprinter()
        .generate(parsed);
    final templateRoleSignature = _templateRoleSignature(parsed);
    final isCompletedValidatedParse =
        parsed.decision == ParseDecision.autoPost &&
        parsed.relevance == FinancialRelevance.transaction &&
        parsed.status == FinancialEventStatus.completed &&
        parsed.selectedAmount != null &&
        parsed.direction != FinancialDirection.unknown &&
        parsed.direction != FinancialDirection.none;
    // Replayed payloads are retained for audit, but they are not independent
    // evidence and therefore cannot promote a learned template.
    final learnedTemplate = !structuralTemplate.canBeLearned
        ? null
        : rawInsert.isExactDuplicate
        ? await _database.getNotificationTemplate(
            fingerprint: structuralTemplate.fingerprint,
            sourcePackage: envelope.packageName,
          )
        : await _database.observeNotificationTemplate(
            fingerprint: structuralTemplate.fingerprint,
            sourcePackage: envelope.packageName,
            fieldPositionMetadata: structuralTemplate.fieldPositionMetadata,
            roleSignature: templateRoleSignature,
            successfulCompletedParse: isCompletedValidatedParse,
            observedAt: envelope.ingestedAt,
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
          classificationMetadata: parsed.classification.metadataJson,
          parseDecision: parsed.decision,
          failureCode: parsed.failureCode ?? 'parser_no_match',
        ),
      );
      await _recordParserDiagnostic(
        parsed: parsed,
        sourceClass: sourceClass,
        structuralFingerprint: structuralTemplate.fingerprint,
        decision: parsed.decision,
        confidence: parsed.overallConfidence,
        failureCode: parsed.failureCode ?? 'parser_no_match',
        observedAt: envelope.ingestedAt,
      );
      await _database.updateRawNotificationProcessingState(
        rawEvent.id!,
        RawNotificationProcessingState.failed,
      );
      await _redactNonReviewRawPayloads();
      return IngestionResult(
        disposition: IngestionDisposition.retained,
        rawEventId: rawEvent.id,
        parsedFinancialEventId: parsedId,
        diagnosticCode: parsed.failureCode ?? 'parser_no_match',
      );
    }

    final accounts = await _database.getAllAccounts();
    final registry =
        institutionRegistry ??
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
    var effectiveConfidence = parsed.overallConfidence;
    // A promoted template is only a bounded confirmation of an already valid,
    // completed parse. It never changes field extraction or status semantics.
    if (learnedTemplate?.isPromoted ?? false) {
      final canUseLearnedConfidence =
          parsed.relevance == FinancialRelevance.transaction &&
          parsed.status == FinancialEventStatus.completed &&
          parsed.selectedAmount != null &&
          parsed.direction != FinancialDirection.unknown &&
          parsed.direction != FinancialDirection.none &&
          (parsed.decision == ParseDecision.autoPost ||
              parsed.decision == ParseDecision.provisional);
      final boostedConfidence = (effectiveConfidence + .08)
          .clamp(0.0, .99)
          .toDouble();
      if (canUseLearnedConfidence) {
        final validation = DefaultParseValidator().validate(
          relevance: parsed.relevance,
          amount: parsed.selectedAmount,
          direction: parsed.direction,
          status: parsed.status,
          overallConfidence: boostedConfidence,
        );
        if (validation.decision == ParseDecision.autoPost) {
          effectiveConfidence = boostedConfidence;
          decision = ParseDecision.autoPost;
          failureCode = null;
        }
      }
    }
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
        !_hasSettledFinancialEffect(parsed.eventType, parsed.status)) {
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
        overallConfidence: effectiveConfidence,
        fieldConfidence: {
          ...parsed.fieldConfidence,
          'account': matchedAccount == null ? 0 : 0.9,
        },
        classificationMetadata: parsed.classification.metadataJson,
        parseDecision: decision,
        failureCode: failureCode,
        ledgerDuplicateConfidence: duplicateAssessment.confidence,
        ledgerDuplicateRationale: duplicateAssessment.rationales
            .map((rationale) => rationale.storageValue)
            .join(','),
      ),
    );
    await _recordParserDiagnostic(
      parsed: parsed,
      sourceClass: sourceClass,
      structuralFingerprint: structuralTemplate.fingerprint,
      decision: decision,
      confidence: effectiveConfidence,
      failureCode: failureCode,
      observedAt: envelope.ingestedAt,
    );

    if (duplicateAssessment.isDefinitive) {
      await _database.linkParsedEventToLedger(
        parsedFinancialEventId: parsedId,
        ledgerEntryId: duplicateAssessment.matchedId!,
        assessment: duplicateAssessment,
      );
      final existingGroupId = await _database
          .getTransactionGroupIdForLedgerEntry(duplicateAssessment.matchedId!);
      final existingGroup = existingGroupId == null
          ? null
          : await _database.getTransactionGroup(existingGroupId);
      final existingLedgerCategory =
          parsed.eventType == FinancialEventType.refund &&
              duplicateAssessment.confidence >= .85
          ? existingGroup?.category?.toLowerCase() == 'salary'
                ? null
                : existingGroup?.category
          : parsed.eventType == FinancialEventType.reversal
          ? existingGroup?.category ?? transactionCategory
          : transactionCategory;
      final related = existingGroupId == null
          ? await _linkRelatedEvent(
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
              applyLifecycleEffects: false,
            )
          : _RelatedEventLink(
              transactionGroupId: existingGroupId,
              ledgerCategory: existingLedgerCategory,
            );
      if (existingGroupId != null) {
        await _database.linkParsedEventToGroup(
          parsedFinancialEventId: parsedId,
          transactionGroupId: existingGroupId,
          assessment: duplicateAssessment,
        );
      }
      await _database.updateLedgerLifecycle(
        ledgerEntryId: duplicateAssessment.matchedId!,
        transactionGroupId: related.transactionGroupId,
        eventRole: _ledgerEventRoleFor(parsed.eventType),
        category: related.ledgerCategory,
      );
      await _database.updateRawNotificationProcessingState(
        rawEvent.id!,
        RawNotificationProcessingState.parsed,
      );
      await _redactNonReviewRawPayloads();
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
          !_hasSettledFinancialEffect(parsed.eventType, parsed.status)) {
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
      await _redactNonReviewRawPayloads();
      return IngestionResult(
        disposition: disposition,
        rawEventId: rawEvent.id,
        parsedFinancialEventId: parsedId,
        diagnosticCode: failureCode,
      );
    }

    final related = await _linkRelatedEvent(
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
    final postedCategory = related.ledgerCategory ?? 'Uncategorized';
    final transactionId = await _database.postIngestedTransaction(
      transaction: Transaction(
        amount: minorToMajor(parsed.selectedAmount!.amountMinor),
        type: parsed.direction == FinancialDirection.credit
            ? TransactionType.credit
            : TransactionType.debit,
        timestamp: parsed.transactionTime ?? postedAt,
        merchant: parsed.merchant.raw ?? 'Unknown',
        category: postedCategory,
        accountId: matchedAccount.id!,
      ),
      parsedFinancialEventId: parsedId,
      transactionGroupId: related.transactionGroupId,
      eventRole: _ledgerEventRoleFor(parsed.eventType),
      ledgerCategory: related.ledgerCategory,
    );
    await _database.updateRawNotificationProcessingState(
      rawEvent.id!,
      RawNotificationProcessingState.posted,
    );
    await _redactNonReviewRawPayloads();
    return IngestionResult(
      disposition: IngestionDisposition.posted,
      rawEventId: rawEvent.id,
      parsedFinancialEventId: parsedId,
      transactionId: transactionId,
    );
  }

  Future<void> _redactNonReviewRawPayloads() async {
    try {
      await _database.redactNonReviewRawNotificationPayloads();
    } catch (_) {
      // Cleanup must not turn an already committed ingestion into a failure.
    }
  }

  Future<void> _recordParserDiagnostic({
    required FinancialParseResult parsed,
    required NotificationSourceClass sourceClass,
    required String structuralFingerprint,
    required ParseDecision decision,
    required double confidence,
    required String? failureCode,
    required DateTime observedAt,
  }) async {
    try {
      await _database.createParserDiagnostic(
        ParserDiagnostic(
          observedAt: observedAt,
          parserVersion: parserVersion,
          extractorsUsed: parsed.extractorsUsed,
          decision: decision.name,
          confidence: confidence,
          failureCode: failureCode,
          sourceCategory: sourceClass.name,
          structuralFingerprint: ParserDiagnosticRedactor.redactFingerprint(
            structuralFingerprint,
          ),
        ),
      );
    } catch (_) {
      // Local diagnostics are best-effort and must never alter ledger state.
    }
  }

  bool _hasStrongTextualEvidence(String text) {
    final hasAmount = RegExp(
      r'(?:₹|rs\.?|inr)\s*[:\-]?\s*\d',
      caseSensitive: false,
    ).hasMatch(text);
    final hasAction = RegExp(
      r'\b(debited|credited|spent|paid|received|withdrawn|deposited|refund|refunded|reversal|reversed|cashback|transferred|transaction\s+of)\b',
      caseSensitive: false,
    ).hasMatch(text);
    final hasInstrumentOrReference = RegExp(
      r'\b(a/c|account|card|upi|vpa|ref(?:erence)?|transaction id|txn id|utr|rrn|hdfc|sbi|icici|axis|kotak|bank)\b',
      caseSensitive: false,
    ).hasMatch(text);
    return hasAmount && hasAction && hasInstrumentOrReference;
  }

  bool _hasSettledFinancialEffect(
    FinancialEventType eventType,
    FinancialEventStatus status,
  ) =>
      status == FinancialEventStatus.completed ||
      (eventType == FinancialEventType.reversal &&
          status == FinancialEventStatus.reversed);

  String _templateRoleSignature(FinancialParseResult parsed) {
    final roles =
        parsed.amountCandidates
            .map((candidate) => candidate.semanticRole.name)
            .toSet()
            .toList()
          ..sort();
    return [
      parsed.relevance.name,
      parsed.direction.name,
      parsed.status.name,
      parsed.eventType.name,
      ...roles,
    ].join('|');
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

  LedgerEventRole _ledgerEventRoleFor(FinancialEventType eventType) =>
      switch (eventType) {
        FinancialEventType.refund => LedgerEventRole.refund,
        FinancialEventType.reversal => LedgerEventRole.reversal,
        FinancialEventType.fee => LedgerEventRole.fee,
        _ => LedgerEventRole.primary,
      };

  Future<_RelatedEventLink> _linkRelatedEvent({
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
    bool applyLifecycleEffects = true,
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
              eventType == FinancialEventType.cashback ||
              eventType == FinancialEventType.transfer
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
      final group = await _database.getTransactionGroup(groupId);
      String? ledgerCategory = category;
      if (eventType == FinancialEventType.refund &&
          assessment.confidence >= .85) {
        ledgerCategory = group?.category?.toLowerCase() == 'salary'
            ? null
            : group?.category;
      } else if (eventType == FinancialEventType.reversal) {
        ledgerCategory = group?.category ?? category;
      }
      if (applyLifecycleEffects &&
          _hasSettledFinancialEffect(eventType, status)) {
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
      return _RelatedEventLink(
        transactionGroupId: groupId,
        ledgerCategory: ledgerCategory,
      );
    }

    final now = DateTime.now().toUtc();
    final ledgerCategory =
        eventType == FinancialEventType.refund &&
            category.toLowerCase() == 'salary'
        ? null
        : category;
    groupId = await _database.createTransactionGroup(
      TransactionGroup(
        groupType: transactionGroupTypeFor(
          eventType: eventType,
          hasOriginalPurchase: false,
        ),
        merchantNormalized: merchant,
        category: ledgerCategory,
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
    return _RelatedEventLink(
      transactionGroupId: groupId,
      ledgerCategory: ledgerCategory,
    );
  }
}
