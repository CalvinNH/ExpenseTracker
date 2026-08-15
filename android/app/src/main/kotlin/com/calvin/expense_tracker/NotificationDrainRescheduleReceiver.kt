package com.calvin.expense_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Repairs background scheduling after reboot, user unlock, and app updates. */
class NotificationDrainRescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in SUPPORTED_ACTIONS) {
            NotificationDrainScheduler.scheduleOutstanding(context)
        }
    }

    private companion object {
        val SUPPORTED_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_USER_UNLOCKED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
        )
    }
}
