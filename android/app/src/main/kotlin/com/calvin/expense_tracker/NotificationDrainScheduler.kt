package com.calvin.expense_tracker

import android.content.Context
import android.os.Build
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/** Durable, offline-only scheduling for the native notification inbox. */
object NotificationDrainScheduler {
    internal const val UNIQUE_WORK_NAME = "notification-inbox-drain-v1"
    internal const val WORK_TAG = "notification-inbox-drain"
    private const val MINIMUM_BACKOFF_SECONDS = 30L
    private const val PREFERENCES = "notification_drain_schedule_v1"
    private const val KEY_STATE = "state"
    private const val KEY_GENERATION = "generation"
    private const val KEY_SCHEDULED_AT = "scheduled_at"
    private val lock = Any()

    fun schedule(context: Context, initialDelayMillis: Long = 0L) {
        if (NativeNotificationInbox.isUsingCustomDebugDatabase(context)) return
        val delay = initialDelayMillis.coerceAtLeast(0L)
        val requestedAt = System.currentTimeMillis() + delay
        synchronized(lock) {
            val preferences = preferences(context)
            val state = DrainScheduleState.fromStorage(
                preferences.getString(KEY_STATE, null),
            )
            val scheduledAt = preferences.getLong(KEY_SCHEDULED_AT, Long.MAX_VALUE)
            val mode = selectDrainEnqueueMode(state, scheduledAt, requestedAt)
            val generation = preferences.getLong(KEY_GENERATION, 0L) + 1L
            preferences.edit().putLong(KEY_GENERATION, generation).apply()

            enqueue(context, delay, mode.policy)
            if (mode != DrainEnqueueMode.keep) {
                preferences.edit()
                    .putString(KEY_STATE, DrainScheduleState.queued.storage)
                    .putLong(KEY_SCHEDULED_AT, requestedAt)
                    .apply()
            }
        }
    }

    /** Marks a worker active and returns the capture generation it owns. */
    fun workerStarted(context: Context): Long = synchronized(lock) {
        val preferences = preferences(context)
        val generation = preferences.getLong(KEY_GENERATION, 0L)
        preferences.edit()
            .putString(KEY_STATE, DrainScheduleState.active.storage)
            .remove(KEY_SCHEDULED_AT)
            .apply()
        generation
    }

    /**
     * Atomically hands work to at most one successor. A capture after an idle
     * decision observes [DrainScheduleState.idle] and appends its own worker,
     * closing the final-empty-check race without one WorkRequest per capture.
     */
    fun workerFinished(
        context: Context,
        startedGeneration: Long,
        state: NativeNotificationInbox.DrainState,
    ) = synchronized(lock) {
        val preferences = preferences(context)
        val currentGeneration = preferences.getLong(KEY_GENERATION, 0L)
        val needsSuccessor =
            state.outstandingCount > 0 || currentGeneration != startedGeneration
        if (!needsSuccessor) {
            preferences.edit()
                .putString(KEY_STATE, DrainScheduleState.idle.storage)
                .remove(KEY_SCHEDULED_AT)
                .apply()
            return@synchronized
        }

        val now = System.currentTimeMillis()
        val delay = state.nextEligibleAtMillis
            ?.minus(now)
            ?.coerceAtLeast(0L)
            ?: 0L
        enqueue(context, delay, ExistingWorkPolicy.APPEND_OR_REPLACE)
        preferences.edit()
            .putString(KEY_STATE, DrainScheduleState.queued.storage)
            .putLong(KEY_SCHEDULED_AT, now + delay)
            .apply()
    }

    private fun enqueue(
        context: Context,
        initialDelayMillis: Long,
        policy: ExistingWorkPolicy,
    ) {
        val request = OneTimeWorkRequestBuilder<NotificationDrainWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.NOT_REQUIRED)
                    .build(),
            )
            .setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                MINIMUM_BACKOFF_SECONDS,
                TimeUnit.SECONDS,
            )
            .addTag(WORK_TAG)
            .build()

        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            UNIQUE_WORK_NAME,
            policy,
            request,
        )
    }

    fun scheduleOutstanding(context: Context) {
        if (NativeNotificationInbox.isUsingCustomDebugDatabase(context)) return
        val state = try {
            NativeNotificationInbox.strictDrainState(context)
        } catch (_: Exception) {
            schedule(context)
            return
        }
        if (state.outstandingCount == 0) return
        val delay = state.nextEligibleAtMillis
            ?.minus(System.currentTimeMillis())
            ?.coerceAtLeast(0L)
            ?: 0L
        schedule(context, delay)
    }

    private fun preferences(context: Context) =
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }).getSharedPreferences(
            PREFERENCES,
            Context.MODE_PRIVATE,
        )
}

internal enum class DrainScheduleState(val storage: String) {
    idle("idle"),
    active("active"),
    queued("queued");

    companion object {
        fun fromStorage(value: String?): DrainScheduleState = entries
            .firstOrNull { it.storage == value }
            ?: idle
    }
}

internal enum class DrainEnqueueMode(val policy: ExistingWorkPolicy) {
    append(ExistingWorkPolicy.APPEND_OR_REPLACE),
    keep(ExistingWorkPolicy.KEEP),
    replace(ExistingWorkPolicy.REPLACE),
}

internal fun selectDrainEnqueueMode(
    state: DrainScheduleState,
    scheduledAtMillis: Long,
    requestedAtMillis: Long,
): DrainEnqueueMode = when (state) {
    DrainScheduleState.idle -> DrainEnqueueMode.append
    DrainScheduleState.active -> DrainEnqueueMode.keep
    DrainScheduleState.queued -> if (requestedAtMillis < scheduledAtMillis) {
        DrainEnqueueMode.replace
    } else {
        DrainEnqueueMode.keep
    }
}
