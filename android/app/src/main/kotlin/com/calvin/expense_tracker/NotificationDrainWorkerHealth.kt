package com.calvin.expense_tracker

import android.content.Context
import android.os.Build

/** Redacted, device-protected telemetry for the bounded background drain. */
object NotificationDrainWorkerHealth {
    private const val PREFERENCES = "notification_drain_worker_health_v1"
    private const val LAST_SUCCESS_AT = "last_success_at"
    private const val LAST_RETRY_AT = "last_retry_at"
    private const val LAST_FAILURE_AT = "last_failure_at"
    private const val LAST_DEFERRED_LOCKED_AT = "last_deferred_locked_at"
    private const val RETRY_COUNT = "retry_count"
    private const val FAILURE_COUNT = "failure_count"
    private const val DEFERRED_LOCKED_COUNT = "deferred_locked_count"
    private const val LAST_INCIDENT_REASON = "last_incident_reason"
    private val lock = Any()

    enum class Reason(val storage: String) {
        userLocked("user_locked"),
        dartRequestedRetry("dart_requested_retry"),
        timedOut("timed_out"),
        nativeOrEngineFailure("native_or_engine_failure");

        companion object {
            fun fromStorage(value: String?): Reason? = entries.firstOrNull {
                it.storage == value
            }
        }
    }

    data class Status(
        val lastSuccessAtMillis: Long,
        val lastRetryAtMillis: Long,
        val lastFailureAtMillis: Long,
        val lastDeferredLockedAtMillis: Long,
        val retryCount: Long,
        val failureCount: Long,
        val deferredLockedCount: Long,
        val lastIncidentReason: Reason?,
    )

    fun recordSuccess(context: Context) {
        synchronized(lock) {
            preferences(context).edit()
                .putLong(LAST_SUCCESS_AT, System.currentTimeMillis())
                .commit()
        }
    }

    fun recordRetry(context: Context, reason: Reason) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(LAST_RETRY_AT, System.currentTimeMillis())
                .putLong(RETRY_COUNT, increment(preferences.getLong(RETRY_COUNT, 0L)))
                .putString(LAST_INCIDENT_REASON, reason.storage)
                .commit()
        }
    }

    fun recordFailure(context: Context, reason: Reason) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(LAST_FAILURE_AT, System.currentTimeMillis())
                .putLong(FAILURE_COUNT, increment(preferences.getLong(FAILURE_COUNT, 0L)))
                .putString(LAST_INCIDENT_REASON, reason.storage)
                .commit()
        }
    }

    fun recordDeferredLocked(context: Context) {
        synchronized(lock) {
            val preferences = preferences(context)
            preferences.edit()
                .putLong(LAST_DEFERRED_LOCKED_AT, System.currentTimeMillis())
                .putLong(
                    DEFERRED_LOCKED_COUNT,
                    increment(preferences.getLong(DEFERRED_LOCKED_COUNT, 0L)),
                )
                .putString(LAST_INCIDENT_REASON, Reason.userLocked.storage)
                .commit()
        }
    }

    fun status(context: Context): Status = synchronized(lock) {
        val preferences = preferences(context)
        Status(
            lastSuccessAtMillis = preferences.getLong(LAST_SUCCESS_AT, 0L),
            lastRetryAtMillis = preferences.getLong(LAST_RETRY_AT, 0L),
            lastFailureAtMillis = preferences.getLong(LAST_FAILURE_AT, 0L),
            lastDeferredLockedAtMillis = preferences.getLong(LAST_DEFERRED_LOCKED_AT, 0L),
            retryCount = preferences.getLong(RETRY_COUNT, 0L),
            failureCount = preferences.getLong(FAILURE_COUNT, 0L),
            deferredLockedCount = preferences.getLong(DEFERRED_LOCKED_COUNT, 0L),
            lastIncidentReason = Reason.fromStorage(
                preferences.getString(LAST_INCIDENT_REASON, null),
            ),
        )
    }

    private fun increment(value: Long): Long =
        if (value == Long.MAX_VALUE) Long.MAX_VALUE else value + 1L

    private fun preferences(context: Context) =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }).getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}
