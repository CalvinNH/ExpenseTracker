package com.calvin.expense_tracker

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Blocks screenshots, screen recording, and the recents preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "expense_tracker/notification_queue"
        ).setMethodCallHandler { call, result ->
            if (call.method != "drain") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val preferences = getSharedPreferences(
                NotificationQueueReceiver.PREFERENCES_NAME,
                MODE_PRIVATE
            )
            val raw = preferences.getString(
                NotificationQueueReceiver.QUEUE_KEY,
                null
            )
            preferences.edit()
                .remove(NotificationQueueReceiver.QUEUE_KEY)
                .apply()

            val queue = try {
                if (raw.isNullOrBlank()) JSONArray() else JSONArray(raw)
            } catch (_: Exception) {
                JSONArray()
            }
            val output = mutableListOf<Map<String, Any?>>()
            for (index in 0 until queue.length()) {
                val item = queue.getJSONObject(index)
                output.add(
                    mapOf(
                        "id" to item.optInt("id"),
                        "packageName" to item.optString("packageName"),
                        "title" to item.optString("title"),
                        "content" to item.optString("content"),
                        "hasRemoved" to item.optBoolean("hasRemoved"),
                        "postTime" to item.optLong("postTime")
                    )
                )
            }
            result.success(output)
        }
    }
}
