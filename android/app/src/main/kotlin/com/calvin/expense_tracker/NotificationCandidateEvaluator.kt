package com.calvin.expense_tracker

/**
 * Source policy shared by capture and ingestion. Keep these sets aligned with
 * `assets/data/notification_sources_v1.json`; a Dart contract test checks the
 * native and Dart registries against that canonical file.
 */
object CanonicalNotificationSources {
    val primaryFinancialPackages = setOf(
        "com.sbi.lotusintouch",
        "com.sbi.SBIFreedomPlus",
        "com.snapwork.hdfc",
        "com.csam.icici.bank.imobile",
        "com.axis.mobile",
        "com.msf.kbank.mobile",
        "com.kotakbank.mobile",
        "com.Version1",
        "com.bankofbaroda.mconnect",
        "com.canarabank.mobility",
        "com.infrasoft.uboi",
        "com.IndianBank.IndOASIS",
        "com.idfcfirstbank.optimus",
        "com.atomyes",
        "com.yesbank",
        "com.fss.indus",
        "com.indusind.indusmobile",
        "com.fedmobile",
        "com.rblbank.mobank",
    )

    val primaryWalletPackages = setOf(
        "net.one97.paytm",
        "com.google.android.apps.nbu.paisa.user",
        "com.phonepe.app",
        "in.org.npci.upiapp",
        "com.mobikwik_new",
        "com.freecharge.android",
    )

    val knownSmsPackages = setOf(
        "com.google.android.apps.messaging",
        "com.samsung.android.messaging",
        "com.android.mms",
        "com.miui.mms",
        "com.oneplus.mms",
    )

    val bestEffortPackages = setOf(
        "com.google.android.gm",
    )

    val corroborationOnlyPackages = setOf(
        "in.amazon.mShop.android.shopping",
        "com.flipkart.android",
        "com.application.zomato",
        "in.swiggy.android",
        "com.ubercab",
        "com.olacabs.customer",
        "com.myntra.android",
    )

    val ignoredPackages = setOf(
        "com.calvin.expense_tracker",
        "android",
        "com.android.systemui",
        "com.google.android.gms",
        "com.android.vending",
        "com.spotify.music",
        "com.google.android.apps.youtube.music",
        "com.google.android.youtube",
        "com.amazon.mp3",
        "com.apple.android.music",
        "org.videolan.vlc",
    )
}

enum class NotificationSourceTier(val priority: Int) {
    primary(3),
    bestEffort(2),
    nonDefaultSms(1),
    corroborationOnly(1),
    unknown(1),
    ignored(0),
}

data class NotificationCandidateInput(
    val packageName: String,
    val defaultSmsPackage: String?,
    val titleVariants: List<String>,
    val bodyVariants: List<String>,
)

data class NotificationCandidateDecision(
    val sourceTier: NotificationSourceTier,
    val isCandidate: Boolean,
    val title: String?,
    val content: String?,
) {
    val priority: Int get() = sourceTier.priority
}

/** Pure evaluator so capture behavior can be exercised without Android. */
object NotificationCandidateEvaluator {
    private val financialAmount = Regex(
        "(?:\\u20B9|rs\\.?|inr|rupees?)\\s*(?:/-|-)?\\s*[0-9][0-9,]*(?:\\.[0-9]{1,2})?",
        RegexOption.IGNORE_CASE,
    )
    private val financialAction = Regex(
        "\\b(debit(?:ed)?|deducted|credit(?:ed)?|charged|paid|payment|received|sent|spent|" +
            "withdrawn|deposited|transfer(?:red)?|refund(?:ed)?|reversed|cashback|" +
            "purchase|transaction|txn)\\b",
        RegexOption.IGNORE_CASE,
    )
    private val settledAction = Regex(
        "\\b(debit(?:ed)?|deducted|credit(?:ed)?|charged|paid|received|sent|spent|withdrawn|" +
            "deposited|transferred|refunded|reversed)\\b",
        RegexOption.IGNORE_CASE,
    )
    private val promotionalLanguage = Regex(
        "\\b(offer|coupon|voucher|sale|win|earn|get|eligible|up\\s+to|flat\\s+[0-9]+%?\\s+off|" +
            "cashback\\s+offer|reward\\s+points?)\\b",
        RegexOption.IGNORE_CASE,
    )
    private val settledPurchase = Regex(
        "\\bpurchase\\s+of\\s+(?:\\u20B9|rs\\.?|inr|rupees?)\\s*(?:/-|-)?\\s*[0-9]",
        RegexOption.IGNORE_CASE,
    )
    private val settledCardUsage = Regex(
        "\\bcard\\b.{0,48}\\b(?:(?:was|has\\s+been)\\s+used|used\\s+(?:at|for|on))\\b",
        setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
    )

    fun evaluate(input: NotificationCandidateInput): NotificationCandidateDecision {
        val titles = sanitize(input.titleVariants, 512)
        val bodies = sanitize(input.bodyVariants, 8192)
        val title = titles.firstOrNull()
        val content = bodies.joinToString("\n").take(8192).ifBlank { null }
        val combinedText = (titles + bodies).joinToString("\n")
        val sourceTier = classify(input.packageName, input.defaultSmsPackage)
        val hasSettledCardUsage = settledCardUsage.containsMatchIn(combinedText)

        // Package identity raises confidence, but is not sufficient by itself:
        // bank, wallet and email apps also emit promotions and service notices.
        val hasStrongTransactionShape =
            financialAmount.containsMatchIn(combinedText) &&
                (financialAction.containsMatchIn(combinedText) || hasSettledCardUsage) &&
                (!promotionalLanguage.containsMatchIn(combinedText) ||
                    settledAction.containsMatchIn(combinedText) ||
                    settledPurchase.containsMatchIn(combinedText))
        return NotificationCandidateDecision(
            sourceTier = sourceTier,
            isCandidate = sourceTier != NotificationSourceTier.ignored && hasStrongTransactionShape,
            title = title,
            content = content,
        )
    }

    fun classify(packageName: String, defaultSmsPackage: String?): NotificationSourceTier {
        val reportedDefault = defaultSmsPackage?.takeIf(String::isNotBlank)
        return when {
            packageName in CanonicalNotificationSources.ignoredPackages -> NotificationSourceTier.ignored
            packageName == reportedDefault -> NotificationSourceTier.primary
            packageName in CanonicalNotificationSources.knownSmsPackages ->
                NotificationSourceTier.nonDefaultSms
            packageName in CanonicalNotificationSources.primaryFinancialPackages -> NotificationSourceTier.primary
            packageName in CanonicalNotificationSources.primaryWalletPackages -> NotificationSourceTier.primary
            packageName in CanonicalNotificationSources.bestEffortPackages -> NotificationSourceTier.bestEffort
            packageName in CanonicalNotificationSources.corroborationOnlyPackages ->
                NotificationSourceTier.corroborationOnly
            else -> NotificationSourceTier.unknown
        }
    }

    private fun sanitize(values: List<String>, maxLength: Int): List<String> = values
        .asSequence()
        .map(String::trim)
        .filter(String::isNotEmpty)
        .map { it.take(maxLength) }
        .distinct()
        .toList()
}
