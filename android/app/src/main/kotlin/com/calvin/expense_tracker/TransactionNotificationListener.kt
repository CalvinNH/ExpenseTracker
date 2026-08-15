package com.calvin.expense_tracker

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** App-owned, minimal notification listener. It persists before Flutter is involved. */
open class TransactionNotificationListener : NotificationListenerService() {
    companion object {
        private const val TAG = "TransactionCapture"
        private const val RECOVERY_CHUNK_SIZE = 64
        private const val MAX_RECOVERY_AGE_MILLIS = 48L * 60L * 60L * 1000L
        const val LISTENER_COMPONENT_CLASS =
            "notification.listener.service.NotificationListener"
        @Volatile var isConnected: Boolean = false
            private set
    }

    private val recoveryExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "transaction-notification-recovery").apply {
                isDaemon = true
            }
        }

    override fun onListenerConnected() {
        super.onListenerConnected()
        isConnected = true
        NativeCaptureHealth.update(this, true)
        recoverActiveNotifications()
        try {
            NotificationDrainScheduler.scheduleOutstanding(this)
        } catch (_: Exception) {
            // The inbox remains durable; a later capture or app resume retries.
        }
    }

    override fun onListenerDisconnected() {
        isConnected = false
        NativeCaptureHealth.update(this, false)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            try {
                requestRebind(ComponentName(this, javaClass))
            } catch (error: Exception) {
                Log.e(TAG, "Unable to request listener rebind", error)
            }
        }
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(notification: StatusBarNotification) {
        capture(notification)
    }

    override fun onDestroy() {
        recoveryExecutor.shutdown()
        super.onDestroy()
    }

    private fun capture(notification: StatusBarNotification) {
        evaluate(notification)?.let(::persist)
    }

    private fun evaluate(notification: StatusBarNotification): NativeNotificationInbox.Capture? =
        try {
            NotificationPayloadExtractor.extract(this, notification)
        } catch (error: Exception) {
            Log.e(TAG, "Unable to evaluate notification", error)
            NativeCaptureHealth.recordStorageFailure(this)
            null
        }

    private fun persist(capture: NativeNotificationInbox.Capture) {
        when (NativeNotificationInbox.enqueue(this, capture)) {
            NativeNotificationInbox.EnqueueOutcome.stored ->
                NativeCaptureHealth.recordCaptured(this, capture.capturedAtMillis)
            NativeNotificationInbox.EnqueueOutcome.storedAfterEviction ->
                NativeCaptureHealth.recordCaptured(this, capture.capturedAtMillis)
            NativeNotificationInbox.EnqueueOutcome.capacityRejected -> Unit
            NativeNotificationInbox.EnqueueOutcome.storageError ->
                NativeCaptureHealth.recordStorageFailure(this)
            NativeNotificationInbox.EnqueueOutcome.duplicate -> Unit
        }
    }

    private fun recoverActiveNotifications() {
        val snapshot = try {
            activeNotifications?.toList().orEmpty()
        } catch (error: Exception) {
            Log.e(TAG, "Unable to read active notifications", error)
            NativeCaptureHealth.recordRecoveryFailure(this)
            return
        }
        if (snapshot.isEmpty()) return

        try {
            recoveryExecutor.execute {
                try {
                    ActiveNotificationRecoveryPlanner.forEachChunk(
                        items = snapshot.asSequence(),
                        nowMillis = System.currentTimeMillis(),
                        maxAgeMillis = MAX_RECOVERY_AGE_MILLIS,
                        chunkSize = RECOVERY_CHUNK_SIZE,
                        postedAtMillis = StatusBarNotification::getPostTime,
                        evaluate = ::evaluate,
                        consume = { chunk -> chunk.forEach(::persist) },
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "Unable to recover active notifications", error)
                    NativeCaptureHealth.recordRecoveryFailure(this)
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Unable to schedule active notification recovery", error)
            NativeCaptureHealth.recordRecoveryFailure(this)
        }
    }

    // Removed notifications are intentionally not queued. They contain less
    // payload on Android and would otherwise displace useful pending events.
    override fun onNotificationRemoved(notification: StatusBarNotification) = Unit
}

internal object NotificationPayloadExtractor {
    fun extract(context: Context, sbn: StatusBarNotification): NativeNotificationInbox.Capture? {
        if (sbn.packageName == context.packageName) return null
        val notification = sbn.notification
        if ((notification.flags and Notification.FLAG_ONGOING_EVENT) != 0) return null
        val extras = notification.extras ?: Bundle.EMPTY
        val decision = NotificationCandidateEvaluator.evaluate(
            NotificationCandidateInput(
                packageName = sbn.packageName,
                defaultSmsPackage = Telephony.Sms.getDefaultSmsPackage(context),
                titleVariants = titleVariants(extras),
                bodyVariants = bodyVariants(extras),
            ),
        )
        if (!decision.isCandidate) return null
        return NativeNotificationInbox.Capture(
            packageName = sbn.packageName,
            notificationKey = sbn.key,
            notificationId = sbn.id,
            notificationTag = sbn.tag,
            title = decision.title,
            content = decision.content,
            postedAtMillis = sbn.postTime,
            capturedAtMillis = System.currentTimeMillis(),
            priority = decision.priority,
            hasRemoved = false,
        )
    }

    private fun titleVariants(extras: Bundle): List<String> = buildList {
        addText(extras.getCharSequence(Notification.EXTRA_TITLE))
        addText(extras.getCharSequence(Notification.EXTRA_TITLE_BIG))
    }

    private fun bodyVariants(extras: Bundle): List<String> = buildList {
        addText(extras.getCharSequence(Notification.EXTRA_TEXT))
        addText(extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.forEach { addText(it) }
        extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.forEach { parcelable ->
            (parcelable as? Bundle)?.getCharSequence("text")?.let { addText(it) }
        }
        addText(extras.getCharSequence(Notification.EXTRA_INFO_TEXT))
        addText(extras.getCharSequence(Notification.EXTRA_SUB_TEXT))
        addText(extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
    }

    private fun MutableList<String>.addText(value: CharSequence?) {
        value?.toString()?.trim()?.takeIf(String::isNotEmpty)?.let(::add)
    }
}

object NativeCaptureHealth {
    private const val PREFERENCES = "notification_capture_health"
    private const val CONNECTED = "connected"
    private const val CHANGED_AT = "changed_at"
    private const val LAST_CAPTURED_AT = "last_captured_at"
    private const val LAST_ACKNOWLEDGED_AT = "last_acknowledged_at"
    private const val ACKNOWLEDGED_COUNT = "acknowledged_count"
    private const val CAPACITY_DROPS = "capacity_drops"
    private const val CAPACITY_EVICTIONS = "capacity_evictions"
    private const val STORAGE_FAILURES = "storage_failures"
    private const val RECOVERY_FAILURES = "recovery_failures"
    private const val LEGACY_MIGRATION_ATTEMPTS = "legacy_migration_attempts"
    private const val LEGACY_MIGRATION_MIGRATED = "legacy_migration_migrated"
    private const val LEGACY_MIGRATION_FAILURES = "legacy_migration_failures"
    private const val LEGACY_MIGRATION_PENDING = "legacy_migration_pending"
    private const val LEGACY_MIGRATION_LAST_ATTEMPT_AT =
        "legacy_migration_last_attempt_at"
    private const val DEBUG_CONTROLS = "native_notification_inbox_test_controls"
    private const val DEBUG_PREFERENCES_NAME = "health_preferences_name"
    private val lock = Any()

    data class Status(
        val connected: Boolean,
        val changedAtMillis: Long,
        val lastCapturedAtMillis: Long,
        val lastAcknowledgedAtMillis: Long,
        val acknowledgedCount: Long,
        val capacityDrops: Long,
        val capacityEvictions: Long,
        val storageFailures: Long,
        val recoveryFailures: Long,
        val legacyMigrationAttempts: Long,
        val legacyMigrationMigrated: Long,
        val legacyMigrationFailures: Long,
        val legacyMigrationPending: Long,
        val legacyMigrationLastAttemptAtMillis: Long,
    )

    fun update(context: Context, connected: Boolean) {
        preferences(context).edit()
            .putBoolean(CONNECTED, connected)
            .putLong(CHANGED_AT, System.currentTimeMillis())
            .commit()
    }

    fun isConnected(context: Context): Boolean = TransactionNotificationListener.isConnected

    fun changedAt(context: Context): Long = preferences(context).getLong(CHANGED_AT, 0)

    fun recordCaptured(context: Context, capturedAtMillis: Long) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(
                    LAST_CAPTURED_AT,
                    maxOf(preferences.getLong(LAST_CAPTURED_AT, 0L), capturedAtMillis),
                )
                .commit()
        }
    }

    fun recordAcknowledged(context: Context, count: Int) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(LAST_ACKNOWLEDGED_AT, System.currentTimeMillis())
                .putLong(
                    ACKNOWLEDGED_COUNT,
                    addSaturated(
                        preferences.getLong(ACKNOWLEDGED_COUNT, 0),
                        count.toLong(),
                    ),
                )
                .commit()
        }
    }

    fun recordStorageFailure(context: Context) = increment(context, STORAGE_FAILURES)

    fun recordRecoveryFailure(context: Context) = increment(context, RECOVERY_FAILURES)

    fun recordLegacyMigration(
        context: Context,
        migrated: Int,
        failed: Int,
        pending: Int,
    ) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(
                    LEGACY_MIGRATION_ATTEMPTS,
                    addSaturated(preferences.getLong(LEGACY_MIGRATION_ATTEMPTS, 0), 1),
                )
                .putLong(
                    LEGACY_MIGRATION_MIGRATED,
                    addSaturated(
                        preferences.getLong(LEGACY_MIGRATION_MIGRATED, 0),
                        migrated.toLong(),
                    ),
                )
                .putLong(
                    LEGACY_MIGRATION_FAILURES,
                    addSaturated(
                        preferences.getLong(LEGACY_MIGRATION_FAILURES, 0),
                        failed.toLong(),
                    ),
                )
                .putLong(LEGACY_MIGRATION_PENDING, pending.toLong())
                .putLong(LEGACY_MIGRATION_LAST_ATTEMPT_AT, System.currentTimeMillis())
                .commit()
        }
    }

    fun status(context: Context): Status = synchronized(lock) {
        val preferences = preferences(context)
        Status(
            connected = isConnected(context),
            changedAtMillis = preferences.getLong(CHANGED_AT, 0),
            lastCapturedAtMillis = preferences.getLong(LAST_CAPTURED_AT, 0),
            lastAcknowledgedAtMillis = preferences.getLong(LAST_ACKNOWLEDGED_AT, 0),
            acknowledgedCount = preferences.getLong(ACKNOWLEDGED_COUNT, 0),
            capacityDrops = preferences.getLong(CAPACITY_DROPS, 0),
            capacityEvictions = preferences.getLong(CAPACITY_EVICTIONS, 0),
            storageFailures = preferences.getLong(STORAGE_FAILURES, 0),
            recoveryFailures = preferences.getLong(RECOVERY_FAILURES, 0),
            legacyMigrationAttempts = preferences.getLong(LEGACY_MIGRATION_ATTEMPTS, 0),
            legacyMigrationMigrated = preferences.getLong(LEGACY_MIGRATION_MIGRATED, 0),
            legacyMigrationFailures = preferences.getLong(LEGACY_MIGRATION_FAILURES, 0),
            legacyMigrationPending = preferences.getLong(LEGACY_MIGRATION_PENDING, 0),
            legacyMigrationLastAttemptAtMillis =
                preferences.getLong(LEGACY_MIGRATION_LAST_ATTEMPT_AT, 0),
        )
    }

    private fun preferences(context: Context) = context.createDeviceProtectedStorageContext()
        .getSharedPreferences(preferencesName(context), Context.MODE_PRIVATE)

    private fun preferencesName(context: Context): String {
        if ((context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
            return PREFERENCES
        }
        return try {
            context.getSharedPreferences(DEBUG_CONTROLS, Context.MODE_PRIVATE)
                .getString(DEBUG_PREFERENCES_NAME, null)
                ?.takeIf { it.matches(Regex("[A-Za-z0-9_.-]{1,100}")) }
                ?: PREFERENCES
        } catch (_: Exception) {
            PREFERENCES
        }
    }

    private fun increment(context: Context, key: String) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(key, addSaturated(preferences.getLong(key, 0), 1))
                .commit()
        }
    }

    private fun addSaturated(value: Long, increment: Long): Long =
        if (increment <= 0L || value >= Long.MAX_VALUE - increment) {
            if (increment <= 0L) value else Long.MAX_VALUE
        } else {
            value + increment
        }
}
