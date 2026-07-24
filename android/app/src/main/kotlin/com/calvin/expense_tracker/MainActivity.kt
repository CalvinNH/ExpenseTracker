package com.calvin.expense_tracker

import android.os.Bundle
import android.view.WindowManager
import android.provider.Telephony
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
            "com.calvin.expense_tracker/system"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDefaultSmsPackage" ->
                    result.success(Telephony.Sms.getDefaultSmsPackage(this))
                else -> result.notImplemented()
            }
        }
    }
}
