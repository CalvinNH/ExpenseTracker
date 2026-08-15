package com.calvin.expense_tracker

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/** Moves the pre-native-inbox SharedPreferences queue without losing rows. */
object LegacyNotificationQueueMigration {
    const val PREFERENCES_NAME = "notification_ingestion_queue"
    const val QUEUE_KEY = "pending_notifications"
    private const val TAG = "LegacyCaptureMigration"
    private const val DEBUG_CONTROLS = "native_notification_inbox_test_controls"
    private const val DEBUG_PREFERENCES_NAME = "legacy_preferences_name"
    private val lock = Any()

    data class Result(
        val migrated: Int,
        val failed: Int,
        val pending: Int,
    )

    fun migrate(context: Context): Result = synchronized(lock) {
        val preferences = context.getSharedPreferences(preferencesName(context), Context.MODE_PRIVATE)
        val raw = preferences.getString(QUEUE_KEY, null)
            ?: return@synchronized Result(0, 0, 0)
        if (raw.isBlank()) {
            if (!preferences.edit().remove(QUEUE_KEY).commit()) {
                NativeCaptureHealth.recordLegacyMigration(context, 0, 1, 1)
                return@synchronized Result(0, 1, 1)
            }
            NativeCaptureHealth.recordLegacyMigration(context, 0, 0, 0)
            return@synchronized Result(0, 0, 0)
        }

        val queue = try {
            JSONArray(raw)
        } catch (error: Exception) {
            Log.e(TAG, "Legacy notification queue is not valid JSON", error)
            NativeCaptureHealth.recordLegacyMigration(context, 0, 1, 1)
            return@synchronized Result(0, 1, 1)
        }

        var migrated = 0
        var failed = 0
        val remaining = JSONArray()
        for (index in 0 until queue.length()) {
            val rawItem = queue.opt(index)
            val item = rawItem as? JSONObject
            if (item == null) {
                remaining.put(rawItem)
                failed += 1
                continue
            }

            val outcome = try {
                NativeNotificationInbox.enqueue(context, item.toCapture())
            } catch (error: Exception) {
                Log.e(TAG, "Unable to migrate legacy notification row", error)
                NativeNotificationInbox.EnqueueOutcome.storageError
            }
            when (outcome) {
                NativeNotificationInbox.EnqueueOutcome.storedAfterEviction,
                NativeNotificationInbox.EnqueueOutcome.capacityRejected -> Unit
                NativeNotificationInbox.EnqueueOutcome.storageError ->
                    NativeCaptureHealth.recordStorageFailure(context)
                else -> Unit
            }
            if (outcome.isDurablyRepresented()) {
                migrated += 1
            } else {
                remaining.put(item)
                failed += 1
            }
        }

        val queueUpdateCommitted = if (remaining.length() == 0) {
            preferences.edit().remove(QUEUE_KEY).commit()
        } else {
            preferences.edit().putString(QUEUE_KEY, remaining.toString()).commit()
        }
        if (!queueUpdateCommitted) {
            // The old rows were not cleared. Re-enqueue is safe because the
            // native inbox de-duplicates them on the next attempt.
            failed += queue.length()
            NativeCaptureHealth.recordLegacyMigration(context, 0, failed, queue.length())
            return@synchronized Result(0, failed, queue.length())
        }

        NativeCaptureHealth.recordLegacyMigration(context, migrated, failed, remaining.length())
        Result(migrated, failed, remaining.length())
    }

    private fun NativeNotificationInbox.EnqueueOutcome.isDurablyRepresented(): Boolean =
        this == NativeNotificationInbox.EnqueueOutcome.stored ||
            this == NativeNotificationInbox.EnqueueOutcome.storedAfterEviction ||
            this == NativeNotificationInbox.EnqueueOutcome.duplicate

    private fun JSONObject.toCapture(): NativeNotificationInbox.Capture {
        val now = System.currentTimeMillis()
        val postedAt = optLong("postTime", now).takeIf { it > 0 } ?: now
        return NativeNotificationInbox.Capture(
            packageName = optString("packageName", ""),
            notificationKey = null,
            notificationId = optInt("id", 0),
            notificationTag = null,
            title = optString("title").ifBlank { null },
            content = optString("content").ifBlank { null },
            postedAtMillis = postedAt,
            capturedAtMillis = postedAt,
            priority = 1,
            hasRemoved = optBoolean("hasRemoved", false),
        )
    }

    private fun preferencesName(context: Context): String {
        if ((context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
            return PREFERENCES_NAME
        }
        return try {
            context.getSharedPreferences(DEBUG_CONTROLS, Context.MODE_PRIVATE)
                .getString(DEBUG_PREFERENCES_NAME, null)
                ?.takeIf { it.matches(Regex("[A-Za-z0-9_.-]{1,100}")) }
                ?: PREFERENCES_NAME
        } catch (_: Exception) {
            PREFERENCES_NAME
        }
    }
}
