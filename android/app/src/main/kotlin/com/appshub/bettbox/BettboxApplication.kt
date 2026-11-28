package com.appshub.bettbox

import android.app.Application
import android.content.Context
import android.os.Build

import com.appshub.bettbox.expiry.SubscriptionExpiryGuard
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngineGroup

class BettboxApplication : Application() {
    companion object {
        private lateinit var instance: BettboxApplication
        fun getAppContext(): Context = instance.applicationContext
    }

    lateinit var engineGroup: FlutterEngineGroup

    override fun onCreate() {
        super.onCreate()
        instance = this
        GlobalState.updateIsStopping(false)
        FlutterInjector.instance().flutterLoader().startInitialization(this)
        engineGroup = FlutterEngineGroup(this)
        // 进程启动时恢复套餐到期闹钟（AlarmManager 闹钟在重启/强杀后可能丢失）
        runCatching { SubscriptionExpiryGuard.reschedule(this) }
    }
}
