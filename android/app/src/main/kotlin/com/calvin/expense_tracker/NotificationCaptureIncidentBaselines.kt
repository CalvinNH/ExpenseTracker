package com.calvin.expense_tracker

import android.content.Context
import android.os.Build

/** User acknowledgement cursors. They never alter or delete source telemetry. */
object NotificationCaptureIncidentBaselines {
    private const val PREFERENCES = "notification_capture_incident_baselines_v1"
    private const val CAPACITY_REJECTED = "capacity_rejected"
    private const val CAPACITY_EVICTED = "capacity_evicted"
    private const val STORAGE_FAILURES = "storage_failures"
    private const val RECOVERY_FAILURES = "recovery_failures"
    private const val WORKER_RETRIES = "worker_retries"
    private const val WORKER_FAILURES = "worker_failures"
    private const val WORKER_DEFERRED_LOCKED = "worker_deferred_locked"
    private const val ACKNOWLEDGED_AT = "acknowledged_at"

    data class Status(
        val capacityRejected: Long,
        val capacityEvicted: Long,
        val storageFailures: Long,
        val recoveryFailures: Long,
        val workerRetries: Long,
        val workerFailures: Long,
        val workerDeferredLocked: Long,
        val acknowledgedAtMillis: Long,
    )

    fun acknowledge(
        context: Context,
        inbox: NativeNotificationInbox.Status,
        health: NativeCaptureHealth.Status,
        worker: NotificationDrainWorkerHealth.Status,
    ) {
        check(inbox.readSucceeded) { "Cannot acknowledge an unreadable native inbox" }
        val committed = preferences(context).edit()
            .putLong(CAPACITY_REJECTED, inbox.capacityRejectedCount)
            .putLong(CAPACITY_EVICTED, inbox.capacityEvictedCount)
            .putLong(STORAGE_FAILURES, health.storageFailures)
            .putLong(RECOVERY_FAILURES, health.recoveryFailures)
            .putLong(WORKER_RETRIES, worker.retryCount)
            .putLong(WORKER_FAILURES, worker.failureCount)
            .putLong(WORKER_DEFERRED_LOCKED, worker.deferredLockedCount)
            .putLong(ACKNOWLEDGED_AT, System.currentTimeMillis())
            .commit()
        check(committed) { "Unable to persist capture-health acknowledgement" }
    }

    fun status(context: Context): Status {
        val preferences = preferences(context)
        return Status(
            capacityRejected = preferences.getLong(CAPACITY_REJECTED, 0L),
            capacityEvicted = preferences.getLong(CAPACITY_EVICTED, 0L),
            storageFailures = preferences.getLong(STORAGE_FAILURES, 0L),
            recoveryFailures = preferences.getLong(RECOVERY_FAILURES, 0L),
            workerRetries = preferences.getLong(WORKER_RETRIES, 0L),
            workerFailures = preferences.getLong(WORKER_FAILURES, 0L),
            workerDeferredLocked = preferences.getLong(WORKER_DEFERRED_LOCKED, 0L),
            acknowledgedAtMillis = preferences.getLong(ACKNOWLEDGED_AT, 0L),
        )
    }

    private fun preferences(context: Context) =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }).getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}
