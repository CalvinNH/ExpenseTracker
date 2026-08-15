package com.calvin.expense_tracker

import android.app.Notification
import android.content.Context
import android.os.Process
import android.service.notification.StatusBarNotification

internal class TransactionNotificationRecoveryInstrumentationTest(
    private val target: Context,
) {
    private val databaseName = "notification-active-recovery.db"
    private val nowMillis = 2_000_000_000L

    fun cases(): List<NativeBehaviorCase> = listOf(
        NativeBehaviorCase(
            suite = "TransactionNotificationRecovery",
            name = "noise ignored and idempotent replay",
        ) {
            setUp()
            try {
                verifyRecovery()
            } finally {
                NativeInboxTestControls.clear(target, databaseName)
            }
        },
    )

    private fun setUp() {
        NativeInboxTestControls.clear(target, databaseName)
        NativeInboxTestControls.configure(target, databaseName, 512, nowMillis)
        NativeNotificationInbox.status(target)
        InboxTestDatabase.clear(target, databaseName)
    }

    private fun verifyRecovery() {
        val newerMediaNoise = (0 until 300).map { index ->
            notification(
                packageName = "com.spotify.music",
                id = index + 1,
                postedAtMillis = nowMillis - index,
                title = "₹${index + 1} debited - soundtrack",
                body = "Now playing",
            )
        }
        val ignoredSystem = notification(
            packageName = "android",
            id = 400,
            postedAtMillis = nowMillis - 400,
            title = "INR 400 credited",
            body = "System status",
        )
        val relevantOlder = notification(
            packageName = "com.snapwork.hdfc",
            id = 500,
            postedAtMillis = nowMillis - 10_000,
            title = "HDFC transaction",
            body = "INR 450.00 debited from A/c XX1234 at Cafe",
        )
        val active = (newerMediaNoise + ignoredSystem + relevantOlder).asSequence()

        fun selected() = buildList {
            ActiveNotificationRecoveryPlanner.forEachChunk(
                items = active,
                nowMillis = nowMillis,
                maxAgeMillis = 48L * 60L * 60L * 1000L,
                chunkSize = 64,
                postedAtMillis = StatusBarNotification::getPostTime,
                evaluate = { NotificationPayloadExtractor.extract(target, it) },
                consume = ::addAll,
            )
        }

        val firstRecovery = selected()
        assertEquals(1, firstRecovery.size)
        assertEquals(500, firstRecovery.single().notificationId)
        assertEquals(
            NativeNotificationInbox.EnqueueOutcome.stored,
            NativeNotificationInbox.enqueue(target, firstRecovery.single()),
        )

        val replay = selected().single()
        assertEquals(
            NativeNotificationInbox.EnqueueOutcome.duplicate,
            NativeNotificationInbox.enqueue(target, replay),
        )
        assertEquals(1, NativeNotificationInbox.status(target).pendingCount)
        val claimed = NativeNotificationInbox.claim(target, 10)
        assertEquals(1, claimed.size)
        assertEquals(500, claimed.single().capture.notificationId)
    }

    private fun notification(
        packageName: String,
        id: Int,
        postedAtMillis: Long,
        title: String,
        body: String,
    ): StatusBarNotification {
        val notification = Notification().apply {
            extras.putCharSequence(Notification.EXTRA_TITLE, title)
            extras.putCharSequence(Notification.EXTRA_TEXT, body)
        }
        return StatusBarNotification(
            packageName,
            packageName,
            id,
            null,
            Process.myUid(),
            Process.myPid(),
            0,
            notification,
            Process.myUserHandle(),
            postedAtMillis,
        )
    }
}
