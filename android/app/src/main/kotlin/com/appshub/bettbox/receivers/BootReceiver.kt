package com.appshub.bettbox.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.expiry.SubscriptionExpiryGuard

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val AUTO_LAUNCH_KEY = "flutter.autoLaunch"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        Log.d(TAG, "Device boot completed, checking autoLaunch setting")

        // 重启会清空 AlarmManager 闹钟，这里重新挂上套餐到期闹钟
        runCatching { SubscriptionExpiryGuard.reschedule(context) }
            .onFailure { Log.e(TAG, "reschedule expiry alarm failed", it) }

        runCatching {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val autoLaunch = prefs.getBoolean(AUTO_LAUNCH_KEY, false)

            if (autoLaunch) {
                Log.d(TAG, "AutoLaunch enabled, triggering silent background boot")
                GlobalState.initServiceEngine(listOf("boot"))
            } else {
                Log.d(TAG, "AutoLaunch disabled, skipping background boot")
            }
        }.onFailure { Log.e(TAG, "Error in BootReceiver", it) }
    }
}
