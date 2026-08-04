package com.calvin.expense_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persists the small text portion of notification-listener broadcasts while
 * the Flutter engine is not running. The Dart side drains this bounded queue
 * at startup and applies its normal parsing and duplicate checks.
 */
class NotificationQueueReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NOTIFICATION_ACTION ||
            intent.getBooleanExtra("connection_event", false)
        ) {
            return
        }

        val receivedAt = System.currentTimeMillis()
        val notificationTime = intent.getLongExtra("notification_time", 0L)
            .takeIf { it > 0L } ?: receivedAt
        val item = JSONObject().apply {
            put("id", intent.getIntExtra("notification_id", 0))
            put("packageName", intent.getStringExtra("package_name") ?: "")
            put("title", intent.getStringExtra("title") ?: "")
            put("content", intent.getStringExtra("message") ?: "")
            put("hasRemoved", intent.getBooleanExtra("is_removed", false))
            put("postTime", notificationTime)
        }

        val preferences =
            context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        synchronized(NotificationQueueReceiver::class.java) {
            val existing = preferences.getString(QUEUE_KEY, null)
            val queue = try {
                if (existing.isNullOrBlank()) JSONArray() else JSONArray(existing)
            } catch (_: Exception) {
                JSONArray()
            }

            val freshQueue = JSONArray()
            val cutoff = receivedAt - MAX_QUEUE_AGE_MILLIS
            for (index in 0 until queue.length()) {
                val queued = queue.optJSONObject(index) ?: continue
                if (queued.optLong("postTime", receivedAt) >= cutoff) {
                    freshQueue.put(queued)
                }
            }
            freshQueue.put(item)
            val trimmed = JSONArray()
            val start = maxOf(0, freshQueue.length() - MAX_QUEUE_SIZE)
            for (index in start until freshQueue.length()) {
                trimmed.put(freshQueue.getJSONObject(index))
            }
            preferences.edit().putString(QUEUE_KEY, trimmed.toString()).apply()
        }
    }

    companion object {
        const val NOTIFICATION_ACTION =
            "slayer.notification.listener.service.intent"
        const val PREFERENCES_NAME = "notification_ingestion_queue"
        const val QUEUE_KEY = "pending_notifications"
        const val MAX_QUEUE_SIZE = 50
        const val MAX_QUEUE_AGE_MILLIS = 24L * 60L * 60L * 1000L
    }
}
