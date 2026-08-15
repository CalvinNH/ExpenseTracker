package com.calvin.expense_tracker

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Shared notification-inbox bridge for both the UI and headless Flutter engines. */
class NotificationCaptureChannelBridge(
    context: Context,
    private val openNotificationSettings: (() -> Unit)? = null,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL_NAME = "expense_tracker/notification_capture"
    }

    private val context = context.applicationContext
    private var channel: MethodChannel? = null
    private val outstandingByLease = linkedMapOf<String, MutableSet<String>>()

    fun install(messenger: BinaryMessenger) {
        check(channel == null) { "Notification capture bridge is already installed" }
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getDefaultSmsPackage" -> result.success(Telephony.Sms.getDefaultSmsPackage(context))
                "hasNotificationAccess" -> result.success(hasNotificationAccess())
                "openNotificationListenerSettings" -> openSettings(result)
                "isListenerConnected" -> result.success(NativeCaptureHealth.isConnected(context))
                "requestListenerRebind" -> result.success(requestListenerRebind())
                "getCaptureStatus" -> result.success(captureStatus())
                "acknowledgeCaptureHealth" -> result.success(acknowledgeCaptureHealth())
                "getHeadlessDrainState" -> {
                    val state = NativeNotificationInbox.strictDrainState(context)
                    result.success(
                        mapOf(
                            "outstandingCount" to state.outstandingCount,
                            "nextEligibleAtMillis" to state.nextEligibleAtMillis,
                        ),
                    )
                }
                "claim" -> claim(call, result)
                "acknowledge" -> acknowledge(call, result)
                "release" -> release(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(
                "native_inbox_failure",
                error.message ?: error.javaClass.simpleName,
                null,
            )
        }
    }

    fun close(releaseOutstanding: Boolean) {
        channel?.setMethodCallHandler(null)
        channel = null
        if (!releaseOutstanding) return
        val snapshot = synchronized(outstandingByLease) {
            outstandingByLease.mapValues { it.value.toList() }.also { outstandingByLease.clear() }
        }
        snapshot.forEach { (leaseToken, ids) ->
            try {
                NativeNotificationInbox.release(context, leaseToken, ids)
            } catch (_: Exception) {
                // Lease expiry is the final recovery path after process/engine failure.
            }
        }
    }

    private fun openSettings(result: MethodChannel.Result) {
        val action = openNotificationSettings
        if (action == null) {
            result.error(
                "headless_ui_forbidden",
                "Notification settings cannot be opened from a headless engine.",
                null,
            )
            return
        }
        action()
        result.success(true)
    }

    private fun claim(call: MethodCall, result: MethodChannel.Result) {
        val limit = (call.argument<Number>("limit")?.toInt() ?: 50).coerceIn(1, 100)
        val claimed = NativeNotificationInbox.claim(context, limit)
        synchronized(outstandingByLease) {
            claimed.forEach { item ->
                outstandingByLease.getOrPut(item.leaseToken, ::linkedSetOf).add(item.id)
            }
        }
        result.success(
            claimed.map { item ->
                mapOf(
                    "inboxId" to item.id,
                    "captureReceiptId" to item.eventHmac,
                    "leaseToken" to item.leaseToken,
                    "packageName" to item.capture.packageName,
                    "notificationKey" to item.capture.notificationKey,
                    "notificationId" to item.capture.notificationId,
                    "notificationTag" to item.capture.notificationTag,
                    "title" to item.capture.title,
                    "content" to item.capture.content,
                    "postTime" to item.capture.postedAtMillis,
                    "capturedAtMillis" to item.capture.capturedAtMillis,
                    "hasRemoved" to item.capture.hasRemoved,
                )
            },
        )
    }

    private fun acknowledge(call: MethodCall, result: MethodChannel.Result) {
        val (leaseToken, ids) = leaseArguments(call)
        val acknowledged = NativeNotificationInbox.acknowledgeStrict(context, leaseToken, ids)
        forgetOutstanding(leaseToken, ids)
        result.success(acknowledged)
    }

    private fun release(call: MethodCall, result: MethodChannel.Result) {
        val (leaseToken, ids) = leaseArguments(call)
        NativeNotificationInbox.release(context, leaseToken, ids)
        forgetOutstanding(leaseToken, ids)
        result.success(null)
    }

    private fun leaseArguments(call: MethodCall): Pair<String, List<String>> {
        val leaseToken = call.argument<String>("leaseToken")
            ?: throw IllegalArgumentException("leaseToken is required")
        val ids = call.argument<List<*>>("ids")
            ?.filterIsInstance<String>()
            ?.distinct()
            ?.takeIf(List<String>::isNotEmpty)
            ?: throw IllegalArgumentException("at least one inbox id is required")
        return leaseToken to ids
    }

    private fun forgetOutstanding(leaseToken: String, ids: List<String>) {
        synchronized(outstandingByLease) {
            val outstanding = outstandingByLease[leaseToken] ?: return
            outstanding.removeAll(ids.toSet())
            if (outstanding.isEmpty()) outstandingByLease.remove(leaseToken)
        }
    }

    private fun captureStatus(): Map<String, Any?> {
        val health = NativeCaptureHealth.status(context)
        val inbox = NativeNotificationInbox.status(context)
        val worker = NotificationDrainWorkerHealth.status(context)
        val baselines = NotificationCaptureIncidentBaselines.status(context)
        return captureStatus(health, inbox, worker, baselines)
    }

    private fun captureStatus(
        health: NativeCaptureHealth.Status,
        inbox: NativeNotificationInbox.Status,
        worker: NotificationDrainWorkerHealth.Status,
        baselines: NotificationCaptureIncidentBaselines.Status,
    ): Map<String, Any?> {
        return mapOf(
            "readSucceeded" to inbox.readSucceeded,
            "accessGranted" to hasNotificationAccess(),
            "listenerConnected" to health.connected,
            "listenerChangedAtMillis" to health.changedAtMillis,
            "lastCapturedAtMillis" to health.lastCapturedAtMillis,
            "lastAcknowledgedAtMillis" to health.lastAcknowledgedAtMillis,
            "acknowledgedCount" to health.acknowledgedCount,
            // These pre-inbox counters are retained only as historical lifetime
            // context. Canonical current capacity incidents come from SQLite.
            "legacyCapacityDropsLifetime" to health.capacityDrops,
            "legacyCapacityEvictionsLifetime" to health.capacityEvictions,
            "storageFailures" to health.storageFailures,
            "recoveryFailures" to health.recoveryFailures,
            "storageFailuresBaseline" to baselines.storageFailures,
            "recoveryFailuresBaseline" to baselines.recoveryFailures,
            "legacyMigrationAttempts" to health.legacyMigrationAttempts,
            "legacyMigrationMigrated" to health.legacyMigrationMigrated,
            "legacyMigrationFailures" to health.legacyMigrationFailures,
            "legacyMigrationPending" to health.legacyMigrationPending,
            "legacyMigrationLastAttemptAtMillis" to health.legacyMigrationLastAttemptAtMillis,
            "pendingCount" to inbox.pendingCount,
            "leasedCount" to inbox.leasedCount,
            "retryingCount" to inbox.retryingCount,
            "quarantinedCount" to inbox.quarantinedCount,
            "deadLetterCount" to inbox.deadLetterCount,
            "capacityRejectedCount" to inbox.capacityRejectedCount,
            "capacityEvictedCount" to inbox.capacityEvictedCount,
            "capacityRejectedBaseline" to baselines.capacityRejected,
            "capacityEvictedBaseline" to baselines.capacityEvicted,
            "oldestPendingAtMillis" to inbox.oldestPendingAtMillis,
            "oldestLeasedAtMillis" to inbox.oldestLeasedAtMillis,
            "healthAcknowledgedAtMillis" to baselines.acknowledgedAtMillis,
            "workerLastSuccessAtMillis" to worker.lastSuccessAtMillis,
            "workerLastRetryAtMillis" to worker.lastRetryAtMillis,
            "workerLastFailureAtMillis" to worker.lastFailureAtMillis,
            "workerLastDeferredLockedAtMillis" to worker.lastDeferredLockedAtMillis,
            "workerRetryCount" to worker.retryCount,
            "workerFailureCount" to worker.failureCount,
            "workerDeferredLockedCount" to worker.deferredLockedCount,
            "workerRetryBaseline" to baselines.workerRetries,
            "workerFailureBaseline" to baselines.workerFailures,
            "workerDeferredLockedBaseline" to baselines.workerDeferredLocked,
            "workerLastIncidentReason" to worker.lastIncidentReason?.storage,
        )
    }

    private fun acknowledgeCaptureHealth(): Map<String, Any?> {
        val inbox = NativeNotificationInbox.status(context)
        val health = NativeCaptureHealth.status(context)
        val worker = NotificationDrainWorkerHealth.status(context)
        NotificationCaptureIncidentBaselines.acknowledge(context, inbox, health, worker)
        val baselines = NotificationCaptureIncidentBaselines.status(context)
        return captureStatus(health, inbox, worker, baselines)
    }

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return enabled.split(':').mapNotNull(ComponentName::unflattenFromString)
            .contains(listenerComponent())
    }

    private fun requestListenerRebind(): Boolean {
        if (!hasNotificationAccess() || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            NotificationListenerService.requestRebind(listenerComponent())
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun listenerComponent() = ComponentName(
        context.packageName,
        TransactionNotificationListener.LISTENER_COMPONENT_CLASS,
    )
}
