package com.calvin.expense_tracker

import android.content.ComponentName
import android.content.Context
import android.provider.Settings

internal class UpgradePreservationInstrumentationTest(
    private val target: Context,
    private val marker: String,
) {
    fun case() = NativeBehaviorCase(
        suite = "UpgradePreservation",
        name = "legacy listener grant and queued capture survive replacement",
    ) {
        val expectedComponent = ComponentName(
            target,
            TransactionNotificationListener.LISTENER_COMPONENT_CLASS,
        )
        val enabledComponents = Settings.Secure.getString(
            target.contentResolver,
            "enabled_notification_listeners",
        ).orEmpty().split(':').mapNotNull(ComponentName::unflattenFromString)
        assertTrue(expectedComponent in enabledComponents)

        val migration = LegacyNotificationQueueMigration.migrate(target)
        assertEquals(1, migration.migrated)
        assertEquals(0, migration.failed)
        assertEquals(0, migration.pending)

        val legacyRaw = target.getSharedPreferences(
            LegacyNotificationQueueMigration.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        ).getString(LegacyNotificationQueueMigration.QUEUE_KEY, null)
        assertTrue(legacyRaw == null || !legacyRaw.contains(marker))

        val claimed = NativeNotificationInbox.claim(target, 100)
        try {
            assertTrue(
                claimed.any { item ->
                    item.capture.title.orEmpty().contains(marker) ||
                        item.capture.content.orEmpty().contains(marker)
                },
            )
        } finally {
            claimed.groupBy { it.leaseToken }.forEach { (leaseToken, items) ->
                NativeNotificationInbox.release(target, leaseToken, items.map { it.id })
            }
        }
    }
}
