package com.appshub.bettbox.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.appshub.bettbox.expiry.SubscriptionExpiryGuard

/** 套餐到期闹钟接收器：到期时在原生侧直接断开连接。 */
class ExpiryAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != null && intent.action != SubscriptionExpiryGuard.ACTION_EXPIRED) return
        runCatching { SubscriptionExpiryGuard.onAlarm(context) }
    }
}
