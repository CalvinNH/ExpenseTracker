package com.calvin.expense_tracker

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A small encrypted, acknowledged inbox that is safe to write before a Flutter
 * engine or SQLCipher database is available. The app-owned listener is the only
 * producer; Flutter claims and acknowledges records after ledger ingestion.
 */
object NativeNotificationInbox {
    private const val TAG = "NativeNotificationInbox"
    private const val DATABASE_NAME = "notification_capture_inbox.db"
    private const val DATABASE_VERSION = 2
    private const val TABLE = "captured_notifications"
    private const val MAX_PENDING_RECORDS = 4096
    private const val DEFAULT_LEASE_MILLIS = 10L * 60L * 1000L
    private const val INITIAL_RETRY_BACKOFF_MILLIS = 30L * 1000L
    private const val MAX_RETRY_BACKOFF_MILLIS = 30L * 60L * 1000L
    private const val MAX_DECODE_FAILURES = 3
    private const val DEAD_LETTER_RETENTION_MILLIS = 30L * 24L * 60L * 60L * 1000L
    private const val DEBUG_CONTROLS = "native_notification_inbox_test_controls"
    private const val DEBUG_DATABASE_NAME = "database_name"
    private const val DEBUG_CAPACITY = "capacity"
    private const val DEBUG_NOW_MILLIS = "now_millis"
    private const val AES_ALIAS = "expense_tracker.notification_inbox.aes.v1"
    private const val HMAC_ALIAS = "expense_tracker.notification_inbox.hmac.v1"
    const val ACTION_INBOX_CHANGED =
        "com.calvin.expense_tracker.NOTIFICATION_INBOX_CHANGED"

    private val lock = Any()
    private val INCIDENT_NAMES = setOf(
        "capacity_rejected",
        "capacity_evicted",
        "decode_quarantined",
        "decode_dead_letter",
    )

    data class Capture(
        val packageName: String,
        val notificationKey: String?,
        val notificationId: Int,
        val notificationTag: String?,
        val title: String?,
        val content: String?,
        val postedAtMillis: Long,
        val capturedAtMillis: Long,
        val priority: Int,
        val hasRemoved: Boolean = false,
    )

    data class ClaimedCapture(
        val id: String,
        val eventHmac: String,
        val leaseToken: String,
        val capture: Capture,
    )

    enum class EnqueueOutcome {
        stored,
        storedAfterEviction,
        duplicate,
        capacityRejected,
        storageError,
    }

    data class Status(
        val readSucceeded: Boolean,
        val pendingCount: Int,
        val leasedCount: Int,
        val retryingCount: Int,
        val quarantinedCount: Int,
        val deadLetterCount: Int,
        val capacityRejectedCount: Long,
        val capacityEvictedCount: Long,
        val oldestPendingAtMillis: Long?,
        val oldestLeasedAtMillis: Long?,
    )

    data class DrainState(
        val outstandingCount: Int,
        val nextEligibleAtMillis: Long?,
    )

    fun enqueue(context: Context, capture: Capture): EnqueueOutcome {
        val outcome = synchronized(lock) {
            val id = UUID.randomUUID().toString()
            try {
            val payload = JSONObject().apply {
                put("packageName", capture.packageName)
                put("notificationKey", capture.notificationKey)
                put("notificationId", capture.notificationId)
                put("notificationTag", capture.notificationTag)
                put("title", capture.title)
                put("content", capture.content)
                put("postedAtMillis", capture.postedAtMillis)
                put("capturedAtMillis", capture.capturedAtMillis)
                put("priority", capture.priority)
                put("hasRemoved", capture.hasRemoved)
            }.toString()
            // Use only stable notification identity fields for de-duplication.
            // `capturedAtMillis` is intentionally excluded: the framework can
            // deliver the same posted notification more than once.
            val eventHmac = eventHmac(
                listOf(
                    capture.packageName,
                    capture.notificationKey.orEmpty(),
                    capture.notificationId.toString(),
                    capture.notificationTag.orEmpty(),
                    capture.title.orEmpty(),
                    capture.content.orEmpty(),
                    capture.postedAtMillis.toString(),
                    capture.hasRemoved.toString(),
                ).joinToString("\u0000"),
            )
            val encryptedPayload = encrypt(id, payload)
            val database = helper(context).writableDatabase
            var evicted = false
            database.beginTransaction()
            try {
                pruneExpiredDeadLetters(database, nowMillis(context))
                val existing = database.rawQuery(
                    "SELECT id FROM $TABLE WHERE event_hmac = ? LIMIT 1",
                    arrayOf(eventHmac),
                )
                existing.use {
                    if (it.moveToFirst()) {
                        database.setTransactionSuccessful()
                        return@synchronized EnqueueOutcome.duplicate
                    }
                }

                val recordCount = database.rawQuery(
                    "SELECT COUNT(*) FROM $TABLE", null,
                ).use { cursor -> cursor.moveToFirst(); cursor.getInt(0) }
                if (recordCount >= maxPendingRecords(context)) {
                    val eviction = database.rawQuery(
                        "SELECT id, priority FROM $TABLE " +
                            "WHERE state != 'leased' " +
                            "ORDER BY priority ASC, captured_at ASC LIMIT 1",
                        null,
                    )
                    eviction.use {
                        if (!it.moveToFirst() || it.getInt(1) >= capture.priority) {
                            Log.e(TAG, "Inbox capacity reached; retained higher-priority records")
                            recordIncident(database, "capacity_rejected", capture.capturedAtMillis)
                            database.setTransactionSuccessful()
                            return@synchronized EnqueueOutcome.capacityRejected
                        }
                        database.delete(TABLE, "id = ?", arrayOf(it.getString(0)))
                        recordIncident(database, "capacity_evicted", capture.capturedAtMillis)
                        evicted = true
                    }
                }
                database.execSQL(
                    "INSERT INTO $TABLE " +
                        "(id, event_hmac, encrypted_payload, state, priority, captured_at, " +
                        "lease_token, lease_expires_at, attempts, decode_failures, next_attempt_at, " +
                        "last_failure_code, last_failure_at) " +
                        "VALUES (?, ?, ?, 'pending', ?, ?, NULL, NULL, 0, 0, 0, NULL, NULL)",
                    arrayOf<Any>(id, eventHmac, encryptedPayload, capture.priority, capture.capturedAtMillis),
                )
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
            if (evicted) EnqueueOutcome.storedAfterEviction else EnqueueOutcome.stored
            } catch (error: Exception) {
                Log.e(TAG, "Unable to durably capture notification", error)
                EnqueueOutcome.storageError
            }
        }
        if (outcome != EnqueueOutcome.storageError) {
            if (outcome == EnqueueOutcome.stored || outcome == EnqueueOutcome.storedAfterEviction) {
                try {
                    notifyInboxChanged(context)
                } catch (error: Exception) {
                    Log.e(TAG, "Unable to broadcast notification inbox change", error)
                }
            }
            try {
                NotificationDrainScheduler.schedule(context)
            } catch (error: Exception) {
                // The native inbox is already durable. WorkManager is only a
                // wake-up mechanism; foreground resume and later captures are
                // recovery paths when scheduling is temporarily unavailable.
                Log.e(TAG, "Unable to schedule notification inbox drain", error)
            }
        }
        return outcome
    }

    fun claim(context: Context, limit: Int = 50): List<ClaimedCapture> = synchronized(lock) {
        require(limit in 1..100) { "Invalid claim limit" }
        val now = nowMillis(context)
        val leaseToken = UUID.randomUUID().toString()
        val claimed = mutableListOf<ClaimedCapture>()
        try {
            val database = helper(context).writableDatabase
            database.beginTransaction()
            try {
                pruneExpiredDeadLetters(database, now)
                database.execSQL(
                    "UPDATE $TABLE SET state = 'pending', lease_token = NULL, lease_expires_at = NULL, " +
                        "next_attempt_at = ? " +
                        "WHERE state = 'leased' AND lease_expires_at <= ?",
                    arrayOf(now + INITIAL_RETRY_BACKOFF_MILLIS, now),
                )
                val cursor = database.rawQuery(
                    "SELECT id, event_hmac, encrypted_payload, decode_failures FROM $TABLE " +
                        "WHERE state IN ('pending', 'quarantined') AND next_attempt_at <= ? " +
                        // captured_at is chronology; id is only a deterministic tie-break,
                        // not a capture sequence.
                        "ORDER BY priority DESC, captured_at ASC, id ASC LIMIT ?",
                    arrayOf(now.toString(), MAX_PENDING_RECORDS.toString()),
                )
                cursor.use {
                    while (it.moveToNext() && claimed.size < limit) {
                        val id = it.getString(0)
                        val eventHmac = it.getString(1)
                        val encryptedPayload = it.getString(2)
                        val previousDecodeFailures = it.getInt(3)
                        try {
                            val capture = decode(decrypt(id, encryptedPayload))
                            database.execSQL(
                                "UPDATE $TABLE SET state = 'leased', lease_token = ?, " +
                                    "lease_expires_at = ?, attempts = attempts + 1, " +
                                    "next_attempt_at = 0, last_failure_code = NULL, last_failure_at = NULL " +
                                    "WHERE id = ? AND state IN ('pending', 'quarantined')",
                                arrayOf(leaseToken, now + DEFAULT_LEASE_MILLIS, id),
                            )
                            claimed.add(ClaimedCapture(id, eventHmac, leaseToken, capture))
                        } catch (error: Exception) {
                            val failures = previousDecodeFailures + 1
                            val terminal = failures >= MAX_DECODE_FAILURES
                            val nextAttemptAt = if (terminal) {
                                Long.MAX_VALUE
                            } else {
                                now + retryBackoffMillis(failures)
                            }
                            database.execSQL(
                                "UPDATE $TABLE SET state = ?, decode_failures = ?, next_attempt_at = ?, " +
                                    "lease_token = NULL, lease_expires_at = NULL, " +
                                    "last_failure_code = ?, last_failure_at = ? WHERE id = ?",
                                arrayOf(
                                    if (terminal) "dead_letter" else "quarantined",
                                    failures,
                                    nextAttemptAt,
                                    safeFailureCode(error),
                                    now,
                                    id,
                                ),
                            )
                            recordIncident(
                                database,
                                if (terminal) "decode_dead_letter" else "decode_quarantined",
                                now,
                            )
                            Log.e(TAG, "Quarantined unreadable inbox row $id", error)
                        }
                    }
                }
                database.setTransactionSuccessful()
            } finally {
                database.endTransaction()
            }
            claimed
        } catch (error: Exception) {
            Log.e(TAG, "Unable to claim captured notifications", error)
            emptyList()
        }
    }

    fun acknowledge(context: Context, leaseToken: String, ids: List<String>): Int = synchronized(lock) {
        if (ids.isEmpty()) return@synchronized 0
        val placeholders = ids.joinToString(",") { "?" }
        val acknowledged = helper(context).writableDatabase.delete(
            TABLE,
            "state = 'leased' AND lease_token = ? AND id IN ($placeholders)",
            arrayOf(leaseToken, *ids.toTypedArray()),
        )
        if (acknowledged > 0) NativeCaptureHealth.recordAcknowledged(context, acknowledged)
        acknowledged
    }

    fun acknowledgeStrict(context: Context, leaseToken: String, ids: List<String>): Int {
        require(ids.isNotEmpty()) { "At least one inbox id is required" }
        val expected = ids.distinct().size
        val acknowledged = acknowledge(context, leaseToken, ids.distinct())
        check(acknowledged == expected) {
            "Acknowledged $acknowledged of $expected leased notification captures"
        }
        return acknowledged
    }

    fun release(context: Context, leaseToken: String, ids: List<String>) = synchronized(lock) {
        if (ids.isEmpty()) return@synchronized
        val placeholders = ids.joinToString(",") { "?" }
        val now = nowMillis(context)
        helper(context).writableDatabase.execSQL(
            "UPDATE $TABLE SET state = 'pending', lease_token = NULL, lease_expires_at = NULL, " +
                "next_attempt_at = ? + CASE " +
                "WHEN attempts <= 1 THEN ? WHEN attempts = 2 THEN ? " +
                "WHEN attempts = 3 THEN ? WHEN attempts = 4 THEN ? ELSE ? END " +
                "WHERE state = 'leased' AND lease_token = ? AND id IN ($placeholders)",
            arrayOf<Any?>(
                now,
                INITIAL_RETRY_BACKOFF_MILLIS,
                INITIAL_RETRY_BACKOFF_MILLIS * 2,
                INITIAL_RETRY_BACKOFF_MILLIS * 4,
                INITIAL_RETRY_BACKOFF_MILLIS * 8,
                MAX_RETRY_BACKOFF_MILLIS,
                leaseToken,
                *ids.toTypedArray(),
            ),
        )
    }

    /** Deletes terminal, unrecoverable payloads only. Pending, quarantined and
     * leased rows are never retention candidates. */
    fun pruneExpiredDeadLetters(context: Context): Int = synchronized(lock) {
        val database = helper(context).writableDatabase
        database.beginTransaction()
        try {
            val deleted = pruneExpiredDeadLetters(database, nowMillis(context))
            database.setTransactionSuccessful()
            deleted
        } finally {
            database.endTransaction()
        }
    }

    private fun pruneExpiredDeadLetters(database: SQLiteDatabase, now: Long): Int =
        database.delete(
            TABLE,
            "id IN (SELECT id FROM $TABLE " +
                "WHERE state = 'dead_letter' AND last_failure_at IS NOT NULL " +
                "AND last_failure_at < ? " +
                "ORDER BY last_failure_at ASC, captured_at ASC, id ASC LIMIT 100)",
            arrayOf((now - DEAD_LETTER_RETENTION_MILLIS).toString()),
        )

    fun status(context: Context): Status = synchronized(lock) {
        try {
            helper(context).readableDatabase.rawQuery(
                "SELECT " +
                    "SUM(CASE WHEN state = 'pending' THEN 1 ELSE 0 END), " +
                    "SUM(CASE WHEN state = 'leased' THEN 1 ELSE 0 END), " +
                    "SUM(CASE WHEN (state = 'pending' AND attempts > 1) OR state = 'quarantined' THEN 1 ELSE 0 END), " +
                    "SUM(CASE WHEN state = 'quarantined' THEN 1 ELSE 0 END), " +
                    "SUM(CASE WHEN state = 'dead_letter' THEN 1 ELSE 0 END), " +
                    "COALESCE((SELECT count FROM capture_incidents WHERE name = 'capacity_rejected'), 0), " +
                    "COALESCE((SELECT count FROM capture_incidents WHERE name = 'capacity_evicted'), 0), " +
                    "MIN(CASE WHEN state = 'pending' THEN captured_at END), " +
                    "MIN(CASE WHEN state = 'leased' THEN captured_at END) " +
                    "FROM $TABLE",
                null,
            ).use { cursor ->
                cursor.moveToFirst()
                Status(
                    readSucceeded = true,
                    pendingCount = cursor.getIntOrZero(0),
                    leasedCount = cursor.getIntOrZero(1),
                    retryingCount = cursor.getIntOrZero(2),
                    quarantinedCount = cursor.getIntOrZero(3),
                    deadLetterCount = cursor.getIntOrZero(4),
                    capacityRejectedCount = cursor.getLongOrZero(5),
                    capacityEvictedCount = cursor.getLongOrZero(6),
                    oldestPendingAtMillis = cursor.getLongOrNull(7),
                    oldestLeasedAtMillis = cursor.getLongOrNull(8),
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "Unable to read capture inbox status", error)
            NativeCaptureHealth.recordStorageFailure(context)
            // A failed read is never represented as an empty, healthy inbox.
            Status(false, 0, 0, 0, 0, 0, 0, 0, null, null)
        }
    }

    /**
     * Strict retry state for headless scheduling. Unlike the user-facing status
     * snapshot, storage failures are propagated so a worker cannot report a
     * false empty inbox.
     */
    fun strictDrainState(context: Context): DrainState = synchronized(lock) {
        helper(context).readableDatabase.rawQuery(
            "SELECT COUNT(*), MIN(CASE " +
                "WHEN state = 'leased' THEN lease_expires_at " +
                "WHEN state IN ('pending', 'quarantined') THEN next_attempt_at " +
                "ELSE NULL END) " +
                "FROM $TABLE WHERE state IN ('pending', 'quarantined', 'leased')",
            null,
        ).use { cursor ->
            check(cursor.moveToFirst()) { "Unable to read native inbox drain state" }
            DrainState(
                outstandingCount = cursor.getIntOrZero(0),
                nextEligibleAtMillis = cursor.getLongOrNull(1),
            )
        }
    }

    private fun decode(payload: String): Capture {
        val json = JSONObject(payload)
        return Capture(
            packageName = json.getString("packageName"),
            notificationKey = json.optString("notificationKey").ifBlank { null },
            notificationId = json.getInt("notificationId"),
            notificationTag = json.optString("notificationTag").ifBlank { null },
            title = json.optString("title").ifBlank { null },
            content = json.optString("content").ifBlank { null },
            postedAtMillis = json.getLong("postedAtMillis"),
            capturedAtMillis = json.getLong("capturedAtMillis"),
            priority = json.getInt("priority"),
            hasRemoved = json.optBoolean("hasRemoved", false),
        )
    }

    private fun retryBackoffMillis(failureCount: Int): Long {
        val exponent = (failureCount - 1).coerceIn(0, 10)
        return (INITIAL_RETRY_BACKOFF_MILLIS * (1L shl exponent))
            .coerceAtMost(MAX_RETRY_BACKOFF_MILLIS)
    }

    private fun safeFailureCode(error: Exception): String =
        error.javaClass.simpleName.take(80).ifBlank { "DecodeFailure" }

    private fun recordIncident(database: SQLiteDatabase, name: String, occurredAtMillis: Long) {
        if (name !in INCIDENT_NAMES) return
        database.execSQL(
            "INSERT OR IGNORE INTO capture_incidents(name, count, last_at) VALUES (?, 0, ?)",
            arrayOf<Any?>(name, occurredAtMillis),
        )
        database.execSQL(
            "UPDATE capture_incidents SET count = CASE " +
                "WHEN count < 9223372036854775807 THEN count + 1 ELSE count END, " +
                "last_at = ? WHERE name = ?",
            arrayOf<Any?>(occurredAtMillis, name),
        )
    }

    private fun helper(context: Context): InboxDatabase {
        val storageContext = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }
        return InboxDatabase(storageContext, databaseName(context))
    }

    private fun databaseName(context: Context): String = debugControls(context)
        ?.getString(DEBUG_DATABASE_NAME, null)
        ?.takeIf { it.matches(Regex("[A-Za-z0-9_.-]{1,80}")) }
        ?: DATABASE_NAME

    internal fun isUsingCustomDebugDatabase(context: Context): Boolean =
        databaseName(context) != DATABASE_NAME

    private fun maxPendingRecords(context: Context): Int = debugControls(context)
        ?.getInt(DEBUG_CAPACITY, MAX_PENDING_RECORDS)
        ?.takeIf { it in 1..MAX_PENDING_RECORDS }
        ?: MAX_PENDING_RECORDS

    private fun nowMillis(context: Context): Long = debugControls(context)
        ?.getLong(DEBUG_NOW_MILLIS, -1L)
        ?.takeIf { it >= 0L }
        ?: System.currentTimeMillis()

    private fun debugControls(context: Context): SharedPreferences? {
        // Release manifests are not debuggable, so release capture can never
        // observe instrumentation overrides.
        if ((context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return null
        return try {
            context.getSharedPreferences(DEBUG_CONTROLS, Context.MODE_PRIVATE)
        } catch (_: Exception) {
            null
        }
    }

    private fun android.database.Cursor.getIntOrZero(index: Int): Int =
        if (isNull(index)) 0 else getInt(index)

    private fun android.database.Cursor.getLongOrZero(index: Int): Long =
        if (isNull(index)) 0 else getLong(index)

    private fun android.database.Cursor.getLongOrNull(index: Int): Long? =
        if (isNull(index)) null else getLong(index)

    private fun notifyInboxChanged(context: Context) {
        context.sendBroadcast(
            android.content.Intent(ACTION_INBOX_CHANGED).setPackage(context.packageName),
        )
    }

    private fun encrypt(id: String, value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, aesKey())
        cipher.updateAAD(id.toByteArray(StandardCharsets.UTF_8))
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val payload = ByteArray(cipher.iv.size + ciphertext.size)
        System.arraycopy(cipher.iv, 0, payload, 0, cipher.iv.size)
        System.arraycopy(ciphertext, 0, payload, cipher.iv.size, ciphertext.size)
        return Base64.encodeToString(payload, Base64.NO_WRAP)
    }

    private fun decrypt(id: String, value: String): String {
        val payload = Base64.decode(value, Base64.NO_WRAP)
        require(payload.size > 12) { "Invalid encrypted inbox payload" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, aesKey(), GCMParameterSpec(128, payload.copyOfRange(0, 12)))
        cipher.updateAAD(id.toByteArray(StandardCharsets.UTF_8))
        return String(cipher.doFinal(payload.copyOfRange(12, payload.size)), StandardCharsets.UTF_8)
    }

    private fun eventHmac(value: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(hmacKey())
        return Base64.encodeToString(mac.doFinal(value.toByteArray(StandardCharsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun aesKey(): SecretKey = keyStore().getKey(AES_ALIAS, null) as? SecretKey
        ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(AES_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }

    private fun hmacKey(): SecretKey = keyStore().getKey(HMAC_ALIAS, null) as? SecretKey
        ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(HMAC_ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private class InboxDatabase(context: Context, name: String) :
        SQLiteOpenHelper(context, name, null, DATABASE_VERSION) {
        override fun onCreate(database: SQLiteDatabase) {
            database.execSQL(
                "CREATE TABLE $TABLE (" +
                    "id TEXT PRIMARY KEY, event_hmac TEXT NOT NULL UNIQUE, encrypted_payload TEXT NOT NULL, " +
                    "state TEXT NOT NULL, priority INTEGER NOT NULL, captured_at INTEGER NOT NULL, " +
                    "lease_token TEXT, lease_expires_at INTEGER, attempts INTEGER NOT NULL, " +
                    "decode_failures INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL DEFAULT 0, " +
                    "last_failure_code TEXT, last_failure_at INTEGER)",
            )
            createV2Objects(database)
        }

        override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                database.execSQL(
                    "ALTER TABLE $TABLE ADD COLUMN decode_failures INTEGER NOT NULL DEFAULT 0",
                )
                database.execSQL(
                    "ALTER TABLE $TABLE ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0",
                )
                database.execSQL("ALTER TABLE $TABLE ADD COLUMN last_failure_code TEXT")
                database.execSQL("ALTER TABLE $TABLE ADD COLUMN last_failure_at INTEGER")
                createV2Objects(database)
            }
        }

        private fun createV2Objects(database: SQLiteDatabase) {
            database.execSQL("DROP INDEX IF EXISTS idx_capture_claim")
            database.execSQL(
                "CREATE INDEX idx_capture_claim ON $TABLE(" +
                    "state, next_attempt_at, priority DESC, captured_at ASC)",
            )
            database.execSQL(
                "CREATE TABLE IF NOT EXISTS capture_incidents (" +
                    "name TEXT PRIMARY KEY, count INTEGER NOT NULL, last_at INTEGER NOT NULL)",
            )
        }
    }
}
