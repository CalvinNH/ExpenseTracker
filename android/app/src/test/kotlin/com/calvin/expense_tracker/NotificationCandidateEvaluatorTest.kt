package com.calvin.expense_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationCandidateEvaluatorTest {
    @Test
    fun `title-only transaction alert is retained`() {
        val decision = NotificationCandidateEvaluator.evaluate(
            NotificationCandidateInput(
                packageName = "com.snapwork.hdfc",
                defaultSmsPackage = null,
                titleVariants = listOf("INR 1,250.00 debited"),
                bodyVariants = emptyList(),
            ),
        )

        assertTrue(decision.isCandidate)
        assertEquals(NotificationSourceTier.primary, decision.sourceTier)
        assertEquals("INR 1,250.00 debited", decision.title)
    }

    @Test
    fun `amount and action can occur in separate text variants`() {
        val decision = NotificationCandidateEvaluator.evaluate(
            NotificationCandidateInput(
                packageName = "com.google.android.gm",
                defaultSmsPackage = null,
                titleVariants = listOf("Payment received"),
                bodyVariants = listOf("Credited to your account", "Rs. 500"),
            ),
        )

        assertTrue(decision.isCandidate)
        assertEquals(NotificationSourceTier.bestEffort, decision.sourceTier)
        assertEquals("Credited to your account\nRs. 500", decision.content)
    }

    @Test
    fun `title variants can split amount and action without body text`() {
        val decision = evaluate(
            packageName = "com.google.android.apps.messaging",
            titles = listOf("HDFC transaction", "Rs. 2,501 credited"),
        )

        assertTrue(decision.isCandidate)
        assertEquals(NotificationSourceTier.primary, decision.sourceTier)
    }

    @Test
    fun `expanded text lines and messages are evaluated together`() {
        val decision = evaluate(
            packageName = "com.snapwork.hdfc",
            titles = listOf("Account update"),
            bodies = listOf("A/c XX1234 was debited", "INR 875.40", "Ref 012345"),
        )

        assertTrue(decision.isCandidate)
        assertEquals("A/c XX1234 was debited\nINR 875.40\nRef 012345", decision.content)
    }

    @Test
    fun `realistic settled transaction vocabulary is retained`() {
        val messages = listOf(
            "Rs. 441 spent on HDFC Bank Card 2613 at SWIGGY",
            "Your A/c XX1234 is credited with ₹2,000.00",
            "INR 95 paid via UPI to Cafe",
            "Rupees 750 withdrawn from ATM",
            "Refund of Rs. 120 received in your account",
            "INR 300 transferred successfully to Ravi",
            "INR 1,499 was charged to your HDFC card at AMAZON",
            "Your card ending 2613 was used for Rs. 825 at CAFE",
            "Card XX2613 used at SWIGGY for INR 441",
        )

        messages.forEach { message ->
            assertTrue(message, evaluate("com.google.android.apps.messaging", bodies = listOf(message)).isCandidate)
        }
    }

    @Test
    fun `otp promotion balance and order noise are rejected`() {
        val noise = listOf(
            "OTP 123456 to pay INR 500. Do not share it.",
            "Get ₹500 cashback on your next payment",
            "Available balance INR 15,000 as of today",
            "Order value INR 899, delivery tomorrow",
            "Get INR 500 off when your card is used for the next order",
            "Your card can be used for purchases up to INR 5,000",
        )

        noise.forEach { message ->
            assertFalse(message, evaluate("com.google.android.apps.messaging", bodies = listOf(message)).isCandidate)
        }
    }

    @Test
    fun `promotional words do not suppress settled cashback or refund`() {
        val settled = listOf(
            "You received ₹50 cashback from an offer",
            "Offer order refund of INR 399 received in your account",
            "Purchase of INR 100 at Cafe. Get reward points",
        )

        settled.forEach { message ->
            assertTrue(message, evaluate("com.phonepe.app", bodies = listOf(message)).isCandidate)
        }
    }

    @Test
    fun `media packages are ignored even when a title resembles a transaction`() {
        val decision = evaluate(
            packageName = "com.spotify.music",
            titles = listOf("₹100 Debited - Scam 1992 Soundtrack"),
            bodies = listOf("Now playing"),
        )

        assertFalse(decision.isCandidate)
        assertEquals(NotificationSourceTier.ignored, decision.sourceTier)
    }

    @Test
    fun `primary best-effort corroboration and unknown tiers stay distinct`() {
        assertEquals(
            NotificationSourceTier.primary,
            evaluate("com.phonepe.app").sourceTier,
        )
        assertEquals(
            NotificationSourceTier.bestEffort,
            evaluate("com.google.android.gm").sourceTier,
        )
        assertEquals(
            NotificationSourceTier.corroborationOnly,
            evaluate("in.amazon.mShop.android.shopping").sourceTier,
        )
        val unknown = evaluate(
            "com.example.unregistered.bank",
            bodies = listOf("INR 250 debited from A/c XX1234"),
        )
        assertEquals(NotificationSourceTier.unknown, unknown.sourceTier)
        assertTrue(unknown.isCandidate)
    }

    @Test
    fun `known package alone does not capture promotions`() {
        val decision = NotificationCandidateEvaluator.evaluate(
            NotificationCandidateInput(
                packageName = "com.phonepe.app",
                defaultSmsPackage = null,
                titleVariants = listOf("Special offer"),
                bodyVariants = listOf("Save more on your next order"),
            ),
        )

        assertFalse(decision.isCandidate)
        assertEquals(NotificationSourceTier.primary, decision.sourceTier)
    }

    @Test
    fun `only reported default SMS package is primary`() {
        assertEquals(
            NotificationSourceTier.primary,
            NotificationCandidateEvaluator.classify(
                "com.google.android.apps.messaging",
                "com.google.android.apps.messaging",
            ),
        )
        assertEquals(
            NotificationSourceTier.nonDefaultSms,
            NotificationCandidateEvaluator.classify(
                "com.samsung.android.messaging",
                "com.google.android.apps.messaging",
            ),
        )
    }

    @Test
    fun `known SMS packages remain non-default without reported default`() {
        assertEquals(
            NotificationSourceTier.nonDefaultSms,
            NotificationCandidateEvaluator.classify("com.samsung.android.messaging", null),
        )
        assertEquals(
            NotificationSourceTier.nonDefaultSms,
            NotificationCandidateEvaluator.classify("com.samsung.android.messaging", ""),
        )
    }

    @Test
    fun `ignored package never captures even transaction-shaped text`() {
        val decision = NotificationCandidateEvaluator.evaluate(
            NotificationCandidateInput(
                packageName = "com.calvin.expense_tracker",
                defaultSmsPackage = null,
                titleVariants = listOf("INR 100 debited"),
                bodyVariants = emptyList(),
            ),
        )

        assertFalse(decision.isCandidate)
        assertEquals(NotificationSourceTier.ignored, decision.sourceTier)
    }

    private fun evaluate(
        packageName: String,
        titles: List<String> = emptyList(),
        bodies: List<String> = emptyList(),
    ): NotificationCandidateDecision = NotificationCandidateEvaluator.evaluate(
        NotificationCandidateInput(
            packageName = packageName,
            defaultSmsPackage = "com.google.android.apps.messaging",
            titleVariants = titles,
            bodyVariants = bodies,
        ),
    )
}
