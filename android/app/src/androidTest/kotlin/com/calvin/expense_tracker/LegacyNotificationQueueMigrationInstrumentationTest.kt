package com.calvin.expense_tracker

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal class LegacyNotificationQueueMigrationInstrumentationTest(
    private val target: Context,
) {
    private lateinit var databaseName: String

    fun cases(): List<NativeBehaviorCase> = listOf(
        case("stored and duplicate rows clear", ::testStoredAndDuplicateRowsAreClearedOnlyAfterDurableEnqueue),
        case("capacity failure retention", ::testCapacityFailureRetainsLegacyRowAndRecordsIncident),
        case("storage failure retention", ::testStorageFailureRetainsLegacyRow),
        case("invalid json retention", ::testInvalidJsonIsRetainedAndReported),
    )

    private fun case(name: String, body: () -> Unit) = NativeBehaviorCase(
        suite = "LegacyNotificationQueueMigration",
        name = name,
    ) {
        setUp(name)
        try {
            body()
        } finally {
            tearDown()
        }
    }

    private fun setUp(name: String) {
        databaseName = "legacy-migration-${name.filter(Char::isLetterOrDigit)}.db"
        NativeInboxTestControls.clear(target, databaseName)
        NativeInboxTestControls.configure(target, databaseName, TEST_CAPACITY, 1_000_000L)
        NativeNotificationInbox.status(target)
        InboxTestDatabase.clear(target, databaseName)
        clearPreferences()
    }

    private fun tearDown() {
        clearPreferences()
        NativeInboxTestControls.clear(target, databaseName)
    }

    private fun testStoredAndDuplicateRowsAreClearedOnlyAfterDurableEnqueue() {
        val raw = legacyQueue(removed = true)
        preferences().edit().putString(LegacyNotificationQueueMigration.QUEUE_KEY, raw).commit()

        val first = LegacyNotificationQueueMigration.migrate(target)
        assertEquals(1, first.migrated)
        assertEquals(0, first.pending)
        assertFalse(preferences().contains(LegacyNotificationQueueMigration.QUEUE_KEY))

        preferences().edit().putString(LegacyNotificationQueueMigration.QUEUE_KEY, raw).commit()
        val duplicate = LegacyNotificationQueueMigration.migrate(target)
        assertEquals(1, duplicate.migrated)
        assertEquals(0, duplicate.pending)
        assertFalse(preferences().contains(LegacyNotificationQueueMigration.QUEUE_KEY))

        val claimed = NativeNotificationInbox.claim(target, 10)
        assertEquals(1, claimed.size)
        assertTrue(claimed.single().capture.hasRemoved)
    }

    private fun testCapacityFailureRetainsLegacyRowAndRecordsIncident() {
        InboxTestDatabase.seedCapacity(target, databaseName, TEST_CAPACITY)
        val raw = legacyQueue()
        preferences().edit().putString(LegacyNotificationQueueMigration.QUEUE_KEY, raw).commit()

        val result = LegacyNotificationQueueMigration.migrate(target)

        assertEquals(0, result.migrated)
        assertEquals(1, result.failed)
        assertEquals(1, result.pending)
        assertEquals(raw, preferences().getString(LegacyNotificationQueueMigration.QUEUE_KEY, null))
        assertEquals(1L, NativeNotificationInbox.status(target).capacityRejectedCount)
        assertEquals(1L, NativeCaptureHealth.status(target).legacyMigrationPending)
    }

    private fun testStorageFailureRetainsLegacyRow() {
        val raw = legacyQueue()
        preferences().edit().putString(LegacyNotificationQueueMigration.QUEUE_KEY, raw).commit()
        InboxTestDatabase.dropCaptureTable(target, databaseName)

        val result = LegacyNotificationQueueMigration.migrate(target)

        assertEquals(0, result.migrated)
        assertEquals(1, result.failed)
        assertEquals(1, result.pending)
        assertEquals(raw, preferences().getString(LegacyNotificationQueueMigration.QUEUE_KEY, null))
        assertTrue(NativeCaptureHealth.status(target).storageFailures > 0)
    }

    private fun testInvalidJsonIsRetainedAndReported() {
        preferences().edit()
            .putString(LegacyNotificationQueueMigration.QUEUE_KEY, "not-json")
            .commit()

        val result = LegacyNotificationQueueMigration.migrate(target)

        assertEquals(0, result.migrated)
        assertEquals(1, result.failed)
        assertEquals(1, result.pending)
        assertEquals(
            "not-json",
            preferences().getString(LegacyNotificationQueueMigration.QUEUE_KEY, null),
        )
        val health = NativeCaptureHealth.status(target)
        assertEquals(1L, health.legacyMigrationFailures)
        assertEquals(1L, health.legacyMigrationPending)
    }

    private fun clearPreferences() {
        preferences().edit().clear().commit()
    }

    private fun preferences() =
        NativeInboxTestControls.legacyPreferences(target, databaseName)

    private fun legacyQueue(removed: Boolean = false): String = JSONArray().apply {
        put(
            JSONObject().apply {
                put("id", 77)
                put("packageName", "legacy.sms")
                put("title", "INR 77 debited")
                put("content", "Legacy transaction")
                put("hasRemoved", removed)
                put("postTime", 77L)
            },
        )
    }.toString()

    private companion object {
        const val TEST_CAPACITY = 8
    }
}
