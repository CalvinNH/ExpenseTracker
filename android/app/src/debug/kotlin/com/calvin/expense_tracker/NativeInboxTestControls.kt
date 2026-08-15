package com.calvin.expense_tracker

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import java.io.File

/** Debug-only controls used by on-device behavioral tests. */
object NativeInboxTestControls {
    private const val PREFERENCES = "native_notification_inbox_test_controls"
    private const val DATABASE_NAME = "database_name"
    private const val CAPACITY = "capacity"
    private const val NOW_MILLIS = "now_millis"
    private const val LEGACY_PREFERENCES_NAME = "legacy_preferences_name"
    private const val HEALTH_PREFERENCES_NAME = "health_preferences_name"

    fun configure(
        context: Context,
        databaseName: String,
        capacity: Int,
        nowMillis: Long,
    ) {
        checkDebuggable(context)
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString(DATABASE_NAME, databaseName)
            .putInt(CAPACITY, capacity)
            .putLong(NOW_MILLIS, nowMillis)
            .putString(LEGACY_PREFERENCES_NAME, legacyPreferencesName(databaseName))
            .putString(HEALTH_PREFERENCES_NAME, healthPreferencesName(databaseName))
            .commit()
    }

    fun setNow(context: Context, nowMillis: Long) {
        checkDebuggable(context)
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putLong(NOW_MILLIS, nowMillis)
            .commit()
    }

    fun databaseFile(context: Context, databaseName: String): File =
        storageContext(context).getDatabasePath(databaseName)

    fun clear(context: Context, databaseName: String) {
        checkDebuggable(context)
        storageContext(context).deleteDatabase(databaseName)
        context.getSharedPreferences(legacyPreferencesName(databaseName), Context.MODE_PRIVATE)
            .edit().clear().commit()
        storageContext(context)
            .getSharedPreferences(healthPreferencesName(databaseName), Context.MODE_PRIVATE)
            .edit().clear().commit()
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().commit()
    }

    fun legacyPreferences(context: Context, databaseName: String) =
        context.getSharedPreferences(legacyPreferencesName(databaseName), Context.MODE_PRIVATE)

    private fun legacyPreferencesName(databaseName: String) = "$databaseName.legacy"

    private fun healthPreferencesName(databaseName: String) = "$databaseName.health"

    private fun storageContext(context: Context): Context =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context.applicationContext
        }

    private fun checkDebuggable(context: Context) {
        check((context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)
    }
}
