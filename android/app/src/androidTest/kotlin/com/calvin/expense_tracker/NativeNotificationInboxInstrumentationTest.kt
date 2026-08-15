package com.calvin.expense_tracker

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Build

internal class NativeNotificationInboxInstrumentationTest(
    private val target: Context,
) {
    private lateinit var databaseName: String
    private var nowMillis = 1_000_000L

    fun cases(): List<NativeBehaviorCase> = listOf(
        case("fresh v2 schema", ::testFreshV2SchemaContainsReliabilityState),
        case("v1 to v2 schema upgrade", ::testSeededV1DatabaseUpgradesInPlace),
        case("lease release expiry acknowledge", ::testLeaseReleaseExpiryAndAcknowledgeLifecycle),
        case("leased capacity protection and incidents", ::testCapacityProtectsLeasedRowsAndRecordsBothIncidents),
        case("corruption quarantine and dead letter", ::testCorruptionDoesNotBlockGoodRowsAndProgressesToDeadLetter),
        case("dead letter retention preserves active states", ::testDeadLetterRetentionPreservesActiveStates),
    )

    private fun case(name: String, body: () -> Unit) = NativeBehaviorCase(
        suite = "NativeNotificationInbox",
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
        nowMillis = 1_000_000L
        databaseName = "notification-inbox-${name.filter(Char::isLetterOrDigit)}.db"
        NativeInboxTestControls.clear(target, databaseName)
        NativeInboxTestControls.configure(target, databaseName, TEST_CAPACITY, nowMillis)
        NativeNotificationInbox.status(target)
        InboxTestDatabase.clear(target, databaseName)
        clearPreferences()
    }

    private fun tearDown() {
        clearPreferences()
        NativeInboxTestControls.clear(target, databaseName)
    }

    private fun testFreshV2SchemaContainsReliabilityState() {
        val columns = InboxTestDatabase.columns(target, databaseName)

        assertTrue(columns.contains("decode_failures"))
        assertTrue(columns.contains("next_attempt_at"))
        assertTrue(columns.contains("last_failure_code"))
        assertTrue(columns.contains("last_failure_at"))
        assertTrue(InboxTestDatabase.tableExists(target, databaseName, "capture_incidents"))
        assertEquals(2, InboxTestDatabase.version(target, databaseName))
    }

    private fun testSeededV1DatabaseUpgradesInPlace() {
        InboxTestDatabase.seedV1(target, databaseName)

        val status = NativeNotificationInbox.status(target)

        assertEquals(1, status.pendingCount)
        assertEquals(2, InboxTestDatabase.version(target, databaseName))
        assertTrue(InboxTestDatabase.columns(target, databaseName).contains("decode_failures"))
        assertTrue(InboxTestDatabase.tableExists(target, databaseName, "capture_incidents"))
        assertEquals("pending", InboxTestDatabase.state(target, databaseName, "v1-row"))
    }

    private fun testLeaseReleaseExpiryAndAcknowledgeLifecycle() {
        assertEquals(
            NativeNotificationInbox.EnqueueOutcome.stored,
            NativeNotificationInbox.enqueue(target, capture(1)),
        )
        val firstClaim = NativeNotificationInbox.claim(target, 1).single()
        assertEquals(1, NativeNotificationInbox.status(target).leasedCount)
        assertTrue(NativeNotificationInbox.claim(target, 1).isEmpty())
        assertEquals(
            0,
            NativeNotificationInbox.acknowledge(target, "wrong-token", listOf(firstClaim.id)),
        )

        NativeNotificationInbox.release(
            target,
            firstClaim.leaseToken,
            listOf(firstClaim.id),
        )
        assertEquals("pending", InboxTestDatabase.state(target, databaseName, firstClaim.id))
        assertTrue(
            InboxTestDatabase.long(target, databaseName, firstClaim.id, "next_attempt_at") >
                nowMillis,
        )
        assertTrue(NativeNotificationInbox.claim(target, 1).isEmpty())

        advanceClock(30_001L)
        val secondClaim = NativeNotificationInbox.claim(target, 1).single()
        assertEquals(firstClaim.id, secondClaim.id)
        assertEquals(
            1,
            NativeNotificationInbox.acknowledge(
                target,
                secondClaim.leaseToken,
                listOf(secondClaim.id),
            ),
        )
        assertEquals(0, NativeNotificationInbox.status(target).pendingCount)
        assertEquals(0, NativeNotificationInbox.status(target).leasedCount)

        assertEquals(
            NativeNotificationInbox.EnqueueOutcome.stored,
            NativeNotificationInbox.enqueue(target, capture(2)),
        )
        val expiring = NativeNotificationInbox.claim(target, 1).single()
        advanceClock(600_001L)
        assertTrue(NativeNotificationInbox.claim(target, 1).isEmpty())
        assertEquals("pending", InboxTestDatabase.state(target, databaseName, expiring.id))
        advanceClock(30_001L)
        val recovered = NativeNotificationInbox.claim(target, 1).single()
        assertEquals(expiring.id, recovered.id)
    }

    private fun testCapacityProtectsLeasedRowsAndRecordsBothIncidents() {
        InboxTestDatabase.seedCapacity(target, databaseName, TEST_CAPACITY)

        val stored = NativeNotificationInbox.enqueue(target, capture(5000, priority = 2))
        assertEquals(NativeNotificationInbox.EnqueueOutcome.storedAfterEviction, stored)
        assertEquals(
            "leased",
            InboxTestDatabase.state(target, databaseName, "leased-low-priority"),
        )
        assertFalse(InboxTestDatabase.exists(target, databaseName, "evictable-low-priority"))

        val rejected = NativeNotificationInbox.enqueue(target, capture(5001, priority = 1))
        assertEquals(NativeNotificationInbox.EnqueueOutcome.capacityRejected, rejected)
        val status = NativeNotificationInbox.status(target)
        assertEquals(1L, status.capacityEvictedCount)
        assertEquals(1L, status.capacityRejectedCount)
        assertEquals(TEST_CAPACITY, InboxTestDatabase.rowCount(target, databaseName))
    }

    private fun testCorruptionDoesNotBlockGoodRowsAndProgressesToDeadLetter() {
        NativeNotificationInbox.enqueue(target, capture(10, priority = 3))
        NativeNotificationInbox.enqueue(target, capture(11, priority = 2))
        val corruptId = InboxTestDatabase.idAtCapturedTime(target, databaseName, 10L)
        InboxTestDatabase.corruptPayload(target, databaseName, corruptId)

        val good = NativeNotificationInbox.claim(target, 10)
        assertEquals(1, good.size)
        assertEquals(11, good.single().capture.notificationId)
        assertEquals(
            "quarantined",
            InboxTestDatabase.state(target, databaseName, corruptId),
        )
        val firstFailureAt = InboxTestDatabase.long(
            target,
            databaseName,
            corruptId,
            "last_failure_at",
        )
        val firstRetryAt = InboxTestDatabase.long(
            target,
            databaseName,
            corruptId,
            "next_attempt_at",
        )
        assertTrue(firstRetryAt > firstFailureAt)
        NativeNotificationInbox.acknowledge(
            target,
            good.single().leaseToken,
            listOf(good.single().id),
        )

        advanceClock(30_001L)
        assertTrue(NativeNotificationInbox.claim(target, 10).isEmpty())
        assertEquals(
            "quarantined",
            InboxTestDatabase.state(target, databaseName, corruptId),
        )
        assertEquals(
            2L,
            InboxTestDatabase.long(target, databaseName, corruptId, "decode_failures"),
        )

        advanceClock(60_001L)
        assertTrue(NativeNotificationInbox.claim(target, 10).isEmpty())
        assertEquals("dead_letter", InboxTestDatabase.state(target, databaseName, corruptId))
        assertEquals(
            3L,
            InboxTestDatabase.long(target, databaseName, corruptId, "decode_failures"),
        )
        val status = NativeNotificationInbox.status(target)
        assertEquals(0, status.quarantinedCount)
        assertEquals(1, status.deadLetterCount)
        assertEquals(
            2L,
            InboxTestDatabase.incidentCount(target, databaseName, "decode_quarantined"),
        )
        assertEquals(
            1L,
            InboxTestDatabase.incidentCount(target, databaseName, "decode_dead_letter"),
        )
    }

    private fun testDeadLetterRetentionPreservesActiveStates() {
        InboxTestDatabase.seedRetentionStates(target, databaseName, nowMillis)
        advanceClock(31L * 24L * 60L * 60L * 1000L)

        assertEquals(1, NativeNotificationInbox.pruneExpiredDeadLetters(target))
        assertFalse(InboxTestDatabase.exists(target, databaseName, "expired-dead"))
        assertEquals("pending", InboxTestDatabase.state(target, databaseName, "old-pending"))
        assertEquals(
            "quarantined",
            InboxTestDatabase.state(target, databaseName, "old-quarantined"),
        )
        assertEquals("leased", InboxTestDatabase.state(target, databaseName, "old-leased"))
        assertEquals(0, NativeNotificationInbox.pruneExpiredDeadLetters(target))
    }

    private fun advanceClock(deltaMillis: Long) {
        nowMillis += deltaMillis
        NativeInboxTestControls.setNow(target, nowMillis)
    }

    private fun clearPreferences() {
        NativeInboxTestControls.legacyPreferences(target, databaseName).edit().clear().commit()
    }

    private fun capture(id: Int, priority: Int = 2) = NativeNotificationInbox.Capture(
        packageName = "test.bank.$id",
        notificationKey = "key-$id",
        notificationId = id,
        notificationTag = null,
        title = "INR $id debited",
        content = "Test transaction $id",
        postedAtMillis = id.toLong(),
        capturedAtMillis = id.toLong(),
        priority = priority,
    )

    private companion object {
        const val TEST_CAPACITY = 8
    }
}

internal object InboxTestDatabase {
    private const val TABLE = "captured_notifications"

    fun clear(context: Context, databaseName: String) {
        database(context, databaseName).use { database ->
            database.delete(TABLE, null, null)
            database.delete("capture_incidents", null, null)
        }
    }

    fun seedV1(context: Context, databaseName: String) {
        storageContext(context).deleteDatabase(databaseName)
        SQLiteDatabase.openOrCreateDatabase(databaseFile(context, databaseName), null).use { database ->
            database.execSQL(
                "CREATE TABLE $TABLE (" +
                    "id TEXT PRIMARY KEY, event_hmac TEXT NOT NULL UNIQUE, " +
                    "encrypted_payload TEXT NOT NULL, state TEXT NOT NULL, " +
                    "priority INTEGER NOT NULL, captured_at INTEGER NOT NULL, " +
                    "lease_token TEXT, lease_expires_at INTEGER, attempts INTEGER NOT NULL)",
            )
            database.execSQL(
                "CREATE INDEX idx_capture_claim ON $TABLE(state, priority DESC, captured_at ASC)",
            )
            database.execSQL(
                "INSERT INTO $TABLE " +
                    "(id, event_hmac, encrypted_payload, state, priority, captured_at, " +
                    "lease_token, lease_expires_at, attempts) " +
                    "VALUES ('v1-row', 'v1-hmac', 'legacy-payload', 'pending', 1, 1, NULL, NULL, 0)",
            )
            database.version = 1
        }
    }

    fun seedCapacity(context: Context, databaseName: String, capacity: Int) {
        database(context, databaseName).use { database ->
            database.beginTransaction()
            try {
                insertRaw(database, "leased-low-priority", 0, "leased", 0)
                insertRaw(database, "evictable-low-priority", 1, "pending", 1)
                for (index in 2 until capacity) {
                    insertRaw(database, "protected-$index", 3, "pending", index.toLong())
                }
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        }
    }

    fun seedRetentionStates(context: Context, databaseName: String, failureAt: Long) {
        database(context, databaseName).use { database ->
            database.beginTransaction()
            try {
                insertRaw(database, "expired-dead", 1, "dead_letter", 1)
                insertRaw(database, "old-pending", 1, "pending", 2)
                insertRaw(database, "old-quarantined", 1, "quarantined", 3)
                insertRaw(database, "old-leased", 1, "leased", 4)
                database.execSQL(
                    "UPDATE $TABLE SET last_failure_at = ? WHERE id IN " +
                        "('expired-dead', 'old-pending', 'old-quarantined', 'old-leased')",
                    arrayOf(failureAt),
                )
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
        }
    }

    private fun insertRaw(
        database: SQLiteDatabase,
        id: String,
        priority: Int,
        state: String,
        capturedAt: Long,
    ) {
        database.execSQL(
            "INSERT INTO $TABLE " +
                "(id, event_hmac, encrypted_payload, state, priority, captured_at, " +
                "lease_token, lease_expires_at, attempts, decode_failures, next_attempt_at, " +
                "last_failure_code, last_failure_at) " +
                "VALUES (?, ?, 'seed', ?, ?, ?, ?, ?, 0, 0, 0, NULL, NULL)",
            arrayOf<Any?>(
                id,
                "hmac-$id",
                state,
                priority,
                capturedAt,
                if (state == "leased") "seed-lease" else null,
                if (state == "leased") Long.MAX_VALUE else null,
            ),
        )
    }

    fun corruptPayload(context: Context, databaseName: String, id: String) {
        database(context, databaseName).use {
            it.execSQL(
                "UPDATE $TABLE SET encrypted_payload = 'not-base64' WHERE id = ?",
                arrayOf(id),
            )
        }
    }

    fun columns(context: Context, databaseName: String): Set<String> =
        database(context, databaseName).use { database ->
            database.rawQuery("PRAGMA table_info($TABLE)", null).use { cursor ->
                val result = mutableSetOf<String>()
                while (cursor.moveToNext()) result.add(cursor.getString(1))
                result
            }
        }

    fun tableExists(context: Context, databaseName: String, name: String): Boolean =
        database(context, databaseName).use { database ->
            database.rawQuery(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                arrayOf(name),
            ).use { it.moveToFirst() }
        }

    fun version(context: Context, databaseName: String): Int =
        database(context, databaseName).use { it.version }

    fun state(context: Context, databaseName: String, id: String): String? =
        database(context, databaseName).use { database ->
            database.rawQuery("SELECT state FROM $TABLE WHERE id = ?", arrayOf(id)).use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        }

    fun exists(context: Context, databaseName: String, id: String): Boolean =
        state(context, databaseName, id) != null

    fun long(context: Context, databaseName: String, id: String, column: String): Long {
        require(column in setOf("next_attempt_at", "last_failure_at", "decode_failures"))
        return database(context, databaseName).use { database ->
            database.rawQuery("SELECT $column FROM $TABLE WHERE id = ?", arrayOf(id)).use {
                check(it.moveToFirst()) { "Missing inbox row $id" }
                it.getLong(0)
            }
        }
    }

    fun idAtCapturedTime(context: Context, databaseName: String, capturedAt: Long): String =
        database(context, databaseName).use { database ->
            database.rawQuery(
                "SELECT id FROM $TABLE WHERE captured_at = ?",
                arrayOf(capturedAt.toString()),
            ).use {
                check(it.moveToFirst()) { "Missing inbox row at $capturedAt" }
                it.getString(0)
            }
        }

    fun rowCount(context: Context, databaseName: String): Int =
        database(context, databaseName).use { database ->
            database.rawQuery("SELECT COUNT(*) FROM $TABLE", null).use {
                it.moveToFirst()
                it.getInt(0)
            }
        }

    fun incidentCount(context: Context, databaseName: String, name: String): Long =
        database(context, databaseName).use { database ->
            database.rawQuery(
                "SELECT count FROM capture_incidents WHERE name = ?",
                arrayOf(name),
            ).use { if (it.moveToFirst()) it.getLong(0) else 0L }
        }

    fun dropCaptureTable(context: Context, databaseName: String) {
        database(context, databaseName).use { it.execSQL("DROP TABLE $TABLE") }
    }

    private fun database(context: Context, databaseName: String): SQLiteDatabase =
        SQLiteDatabase.openDatabase(
            databaseFile(context, databaseName).absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )

    private fun databaseFile(context: Context, databaseName: String) =
        NativeInboxTestControls.databaseFile(context, databaseName)

    fun storageContext(context: Context): Context =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }
}
