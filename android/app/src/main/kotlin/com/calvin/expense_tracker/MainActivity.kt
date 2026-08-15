package com.calvin.expense_tracker

import android.os.Bundle
import android.provider.Settings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.view.View
import android.view.WindowManager
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterFragmentActivity() {
    private var captureEvents: EventChannel.EventSink? = null
    private var captureReceiver: BroadcastReceiver? = null
    private var captureBridge: NotificationCaptureChannelBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Blocks screenshots, screen recording, and the recents preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        hideNavigationBar()
        LegacyNotificationQueueMigration.migrate(applicationContext)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // A transient system gesture can reveal navigation. Re-hide it after
        // system UI or another activity gives this secure screen focus again.
        if (hasFocus) hideNavigationBar()
    }

    private fun hideNavigationBar() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.apply {
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsets.Type.navigationBars())
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "expense_tracker/device_timezone"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getLocalTimeZone") {
                result.success(TimeZone.getDefault().id)
            } else {
                result.notImplemented()
            }
        }
        captureBridge = NotificationCaptureChannelBridge(
            context = this,
            openNotificationSettings = {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            },
        ).also { it.install(flutterEngine.dartExecutor.binaryMessenger) }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "expense_tracker/notification_capture_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                captureEvents = events
                if (captureReceiver == null) {
                    captureReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            if (intent.action == NativeNotificationInbox.ACTION_INBOX_CHANGED) {
                                captureEvents?.success(null)
                            }
                        }
                    }
                    val filter = IntentFilter(NativeNotificationInbox.ACTION_INBOX_CHANGED)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(captureReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(captureReceiver, filter)
                    }
                }
            }

            override fun onCancel(arguments: Any?) {
                captureEvents = null
                captureReceiver?.let(::unregisterReceiver)
                captureReceiver = null
            }
        })
    }

    override fun onDestroy() {
        captureReceiver?.let(::unregisterReceiver)
        captureReceiver = null
        captureEvents = null
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        captureBridge?.close(releaseOutstanding = true)
        captureBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
