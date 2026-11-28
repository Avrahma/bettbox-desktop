package com.appshub.bettbox.expiry

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.MainActivity
import com.appshub.bettbox.R
import com.appshub.bettbox.RunState
import com.appshub.bettbox.core.Core
import com.appshub.bettbox.plugins.ServicePlugin
import com.appshub.bettbox.plugins.VpnPlugin
import com.appshub.bettbox.receivers.ExpiryAlarmReceiver
import com.appshub.bettbox.services.BettboxService
import com.appshub.bettbox.services.BettboxVpnService
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * 套餐到期原生守卫。
 *
 * 三级保障，全部在原生层完成，不依赖 Flutter 引擎/Dart 定时器是否存活：
 * 1. AlarmManager 闹钟（优先精确闹钟，不允许时降级 setAlarmClock，保证到点唤醒 CPU）；
 * 2. 到期前 30 分钟自动持一把局部 WakeLock，保证 VPN 服务内看门狗线程不被休眠冻结；
 * 3. VPN 服务内的 2 秒看门狗线程（[checkNow]），闹钟被系统延迟时兜底。
 *
 * 到期后直接停内核 + 停服务，不依赖 GlobalState 的状态判定。
 */
object SubscriptionExpiryGuard {
    const val PREFS_NAME = "vpn_state"
    const val ACTION_EXPIRED = "com.appshub.bettbox.action.SUBSCRIPTION_EXPIRED"

    private const val TAG = "SubExpiryGuard"
    private const val KEY_DEADLINE = "sub_expires_at_ms"
    private const val KEY_AUTO_STOPPED = "sub_expired_auto_stop"
    private const val KEY_LAST_STOP_AT = "sub_expired_last_stop_at"
    private const val KEY_LAST_ALARM_AT = "sub_expired_last_alarm_at"
    private const val KEY_LAST_SCHEDULE_AT = "sub_expiry_last_schedule_at"
    private const val KEY_SCHEDULE_MODE = "sub_expiry_schedule_mode"
    private const val KEY_SCHEDULE_COUNT = "sub_expiry_schedule_count"
    private const val KEY_WATCH_TICKS = "sub_expiry_watch_ticks"
    private const val KEY_TEST_MODE = "sub_expiry_test_mode"
    private const val KEY_TEST_STOPPED = "sub_expiry_test_stopped"
    private const val KEY_DART_SYNC_AT = "sub_expiry_dart_sync_at"
    private const val KEY_SERVER_POLL_AT = "sub_expiry_server_poll_at"
    private const val KEY_SERVER_STATE = "sub_expiry_server_state"
    private const val KEY_SERVER_STOP_AT = "sub_expiry_server_stop_at"
    private const val REQUEST_CODE = 2001
    private const val REQUEST_CODE_SHOW = 2002
    private const val CHANNEL_ID = "expiry_alert"
    private const val NOTIFICATION_ID = 2001

    /** 到期前多久开始持 WakeLock（保证临近到期时看门狗线程可运行）。 */
    private const val NEAR_EXPIRY_WINDOW_MS = 30 * 60 * 1000L

    /** VPN 运行期间向服务端核对套餐状态的间隔。 */
    private const val SERVER_POLL_INTERVAL_S = 60L

    /** Flutter 端 SharedPreferences 名与键（读取登录 token / 服务器地址）。 */
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val KEY_FLUTTER_TOKEN = "flutter.app_client_token"
    private const val KEY_FLUTTER_BASE = "flutter.app_client_base"
    private const val DEFAULT_BASE_URL = "https://s.553786.xyz"

    /** 重复触发抑制窗口。 */
    private const val STOP_DEDUP_MS = 10 * 1000L

    @Volatile
    private var wakeLock: PowerManager.WakeLock? = null

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun deadlineMillis(context: Context): Long =
        runCatching { prefs(context).getLong(KEY_DEADLINE, 0L) }.getOrDefault(0L)

    /**
     * Dart 侧每次刷新套餐信息后同步到期时间。
     *
     * @param expiresAtMillis 到期时间戳（毫秒），0 表示无到期时间（长期有效/未登录）
     * @param expired 服务端或本地已判定到期
     */
    fun setDeadline(context: Context, expiresAtMillis: Long, expired: Boolean) {
        val appContext = context.applicationContext
        val now = System.currentTimeMillis()
        val current = prefs(appContext)
        current.edit().putLong(KEY_DART_SYNC_AT, now).apply()
        // 自检模式：模拟到期未触发前，忽略 Dart 侧同步，避免把模拟闹钟覆盖掉
        if (current.getBoolean(KEY_TEST_MODE, false)) {
            val simulated = current.getLong(KEY_DEADLINE, 0L)
            if (simulated > now) return
            current.edit().putBoolean(KEY_TEST_MODE, false).apply()
        }
        val target = when {
            // 已停止连接时无需再断开，避免反复空转挂闹钟
            expired -> if (GlobalState.currentRunState != RunState.STOP) now + 500L else 0L
            expiresAtMillis > 0L -> expiresAtMillis
            else -> 0L
        }
        val editor = prefs(appContext).edit().putLong(KEY_DEADLINE, target)
        if (target <= 0L || target > now) {
            // 续费/换套餐后清除上一轮的自动断开标记
            editor.putBoolean(KEY_AUTO_STOPPED, false)
        }
        editor.apply()

        if (target <= 0L) {
            cancelAlarm(appContext)
        } else {
            schedule(appContext, target)
        }
    }

    /** 进程启动 / 开机后恢复闹钟（AlarmManager 的闹钟在重启后失效）。 */
    fun reschedule(context: Context) {
        val appContext = context.applicationContext
        val target = deadlineMillis(appContext)
        if (target > 0L) {
            schedule(appContext, target)
        }
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, ExpiryAlarmReceiver::class.java).apply {
            action = ACTION_EXPIRED
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    private fun showIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, REQUEST_CODE_SHOW, intent, flags)
    }

    private fun schedule(context: Context, atMillis: Long) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val pi = pendingIntent(context)
        val now = System.currentTimeMillis()
        val trigger = atMillis.coerceAtLeast(now + 500L)
        acquireWakeLockIfNear(context, trigger - now)

        val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            runCatching { am.canScheduleExactAlarms() }.getOrDefault(false)

        val ok = if (exactAllowed) {
            runCatching {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                true
            }.getOrElse { false }
        } else {
            false
        }
        if (ok) {
            markScheduled(context, trigger, "exact")
            Log.i(TAG, "exact alarm scheduled at $trigger")
            return
        }
        // setAlarmClock 始终精确且能唤醒设备，且不受「精确闹钟授权」限制（状态栏会显示闹钟图标）
        val clockOk = runCatching {
            am.setAlarmClock(AlarmManager.AlarmClockInfo(trigger, showIntent(context)), pi)
            true
        }.getOrElse { false }
        if (clockOk) {
            markScheduled(context, trigger, "alarmClock")
            Log.w(TAG, "exact alarm denied, fallback to setAlarmClock at $trigger")
            return
        }
        runCatching { am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi) }
            .onSuccess { markScheduled(context, trigger, "inexact") }
            .onFailure { Log.e(TAG, "schedule alarm failed: ${it.message}") }
    }

    private fun markScheduled(context: Context, trigger: Long, mode: String) {
        val p = prefs(context)
        p.edit()
            .putLong(KEY_LAST_SCHEDULE_AT, System.currentTimeMillis())
            .putLong("sub_expiry_alarm_trigger", trigger)
            .putString(KEY_SCHEDULE_MODE, mode)
            .putInt(KEY_SCHEDULE_COUNT, p.getInt(KEY_SCHEDULE_COUNT, 0) + 1)
            .apply()
    }

    private fun cancelAlarm(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val pi = pendingIntent(context)
        runCatching { am?.cancel(pi) }
        runCatching { pi.cancel() }
        runCatching { am?.cancel(showIntent(context)) }
        releaseWakeLock()
    }

    @Synchronized
    private fun acquireWakeLockIfNear(context: Context, remainingMs: Long) {
        if (remainingMs <= 0L || remainingMs > NEAR_EXPIRY_WINDOW_MS) return
        if (wakeLock?.isHeld == true) return
        runCatching {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bettbox:expiry")
            lock.setReferenceCounted(false)
            lock.acquire(remainingMs + 5 * 60 * 1000L)
            wakeLock = lock
            Log.i(TAG, "near expiry, partial wakelock held for ${remainingMs}ms")
        }.onFailure { Log.w(TAG, "acquire wakelock failed: ${it.message}") }
    }

    @Synchronized
    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    /** 闹钟触发 / 轮询检查：到期则直接断开连接。 */
    fun onAlarm(context: Context) {
        val appContext = context.applicationContext
        val target = deadlineMillis(appContext)
        if (target <= 0L) return
        val now = System.currentTimeMillis()
        if (now < target - 1500L) {
            // 系统提前唤醒，重新挂上剩余时间
            schedule(appContext, target)
            return
        }
        // 拆连接需要几秒 CPU，先持锁避免刚唤醒又被休眠打断
        acquireTearDownWakeLock(appContext)
        val lastStop = runCatching { prefs(appContext).getLong(KEY_LAST_STOP_AT, 0L) }.getOrDefault(0L)
        if (lastStop > 0L && now - lastStop < STOP_DEDUP_MS) return
        prefs(appContext).edit()
            .putLong(KEY_LAST_ALARM_AT, now)
            .putLong(KEY_LAST_STOP_AT, now)
            .apply()
        hardStop(appContext)
    }

    @Synchronized
    private fun acquireTearDownWakeLock(context: Context) {
        runCatching {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "bettbox:expiry-stop")
            lock.setReferenceCounted(false)
            lock.acquire(30 * 1000L)
        }
    }

    /** VPN 运行期间的高频轮询兜底（前台服务进程内执行，不受 Flutter 引擎存活影响）。 */
    fun checkNow(context: Context) {
        val appContext = context.applicationContext
        val p = prefs(appContext)
        runCatching { p.edit().putLong(KEY_WATCH_TICKS, p.getLong(KEY_WATCH_TICKS, 0L) + 1L).apply() }
        val target = deadlineMillis(appContext)
        if (target <= 0L) return
        if (System.currentTimeMillis() < target) return
        onAlarm(appContext)
    }

    /**
     * 到期硬断开：不依赖 GlobalState/VpnPlugin 的可用性，
     * 内核、VPN 服务、通知、状态逐项强制收尾，保证后台也能真正断开。
     */
    private fun hardStop(context: Context) {
        val app = context.applicationContext
        val wasRunning = GlobalState.currentRunState != RunState.STOP
        Log.w(TAG, "subscription expired, hard stop (running=$wasRunning)")

        if (wasRunning) {
            val p = prefs(app)
            val editor = p.edit().putBoolean(KEY_AUTO_STOPPED, true)
            if (p.getBoolean(KEY_TEST_MODE, false)) {
                editor.putBoolean(KEY_TEST_STOPPED, true)
            }
            editor.apply()
        }

        // 1. 走一遍插件侧标准停止（清代理运行态、解绑服务、取消通知）
        runCatching { VpnPlugin.handleStop(force = true) }
            .onFailure { Log.w(TAG, "VpnPlugin.handleStop failed: ${it.message}") }

        // 2. 兜底：直接停内核与前台服务，防止插件状态异常时残留隧道
        runCatching { Core.stopTun() }
            .onFailure { Log.w(TAG, "Core.stopTun failed: ${it.message}") }
        runCatching { app.stopService(Intent(app, BettboxVpnService::class.java)) }
        runCatching { app.stopService(Intent(app, BettboxService::class.java)) }

        // 3. 同步状态给 Dart（若引擎还在）
        runCatching { GlobalState.updateRunState(RunState.STOP) }
        runCatching { ServicePlugin.notifyRunStateChanged(RunState.STOP) }
        runCatching {
            app.getSystemService(NotificationManager::class.java)
                ?.cancel(GlobalState.NOTIFICATION_ID)
        }

        // 4. 闹钟收尾 + 用户可见提示
        prefs(app).edit().putLong(KEY_DEADLINE, 0L).apply()
        cancelAlarm(app)
        if (wasRunning) {
            notifyExpired(app)
        }
    }

    private fun notifyExpired(context: Context) {
        runCatching {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "套餐到期提醒",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply { description = "套餐到期自动断开连接时提醒" }
                nm.createNotificationChannel(channel)
            }
            val content = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            val contentPi = PendingIntent.getActivity(context, REQUEST_CODE_SHOW, content, flags)
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic)
                .setContentTitle("当前套餐已到期")
                .setContentText("连接已自动断开，续费后可继续使用")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(contentPi)
                .build()
            nm.notify(NOTIFICATION_ID, notification)
        }.onFailure { Log.w(TAG, "notifyExpired failed: ${it.message}") }
    }

    // ------------------------------------------------------------------
    // 服务端口径的到期核对（后台常驻，不依赖 Flutter 引擎/Dart 是否存活）
    // ------------------------------------------------------------------

    @Volatile
    private var serverPoller: ScheduledExecutorService? = null

    /** VPN 服务启动时调用：每 60 秒向服务端核对一次套餐，服务端判到期就地断开。 */
    @Synchronized
    fun startServerPoller(context: Context) {
        if (serverPoller != null) return
        val appContext = context.applicationContext
        val exec = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "bettbox-expiry-server-poll").also { it.isDaemon = true }
        }
        serverPoller = exec
        runCatching {
            exec.scheduleWithFixedDelay(
                {
                    runCatching { pollServerOnce(appContext) }
                        .onFailure { Log.w(TAG, "server poll failed: ${it.message}") }
                },
                2L,
                SERVER_POLL_INTERVAL_S,
                TimeUnit.SECONDS,
            )
        }.onFailure { Log.w(TAG, "start server poller failed: ${it.message}") }
    }

    @Synchronized
    fun stopServerPoller() {
        runCatching { serverPoller?.shutdownNow() }
        serverPoller = null
    }

    /**
     * 拉一次 /api/app/profile：
     * - 服务端返回 expired=true 且当前仍在连接 → 直接硬断开（后台也生效）；
     * - 未到期 → 用服务端日期校正本地到期时间，修正手机时间/时区偏差。
     */
    private fun pollServerOnce(context: Context) {
        val flutterPrefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val p = prefs(context)
        val token = flutterPrefs.getString(KEY_FLUTTER_TOKEN, null)
        if (token.isNullOrBlank()) {
            recordServerState(p, "未登录，跳过核对")
            return
        }
        val rawBase = flutterPrefs.getString(KEY_FLUTTER_BASE, null)?.trim().orEmpty()
        val base = (rawBase.ifEmpty { DEFAULT_BASE_URL }).trimEnd('/')
        val conn = (URL("$base/api/app/profile").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 8000
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/json")
            setRequestProperty("X-Device-Platform", "android")
        }
        try {
            val code = conn.responseCode
            if (code == HttpURLConnection.HTTP_UNAUTHORIZED) {
                recordServerState(p, "登录态已失效(401)")
                return
            }
            if (code !in 200..299) {
                recordServerState(p, "服务器返回 $code")
                return
            }
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            val obj = JSONObject(text)
            val primary = obj.optJSONObject("primary")
            if (primary == null) {
                recordServerState(p, "服务端未下发套餐")
                return
            }
            val expired = primary.optBoolean("expired", false)
            val daysLeft = primary.optInt("days_left", -1)
            val expiresOn = primary.optString("expires_on", "")
            val planName = primary.optString("plan_name", "")
            recordServerState(
                p,
                if (expired) {
                    "已到期 plan=$planName expires_on=$expiresOn days_left=$daysLeft"
                } else {
                    "生效中 plan=$planName expires_on=$expiresOn days_left=$daysLeft"
                },
            )

            if (expired) {
                val running = GlobalState.currentRunState != RunState.STOP
                if (running) {
                    val now = System.currentTimeMillis()
                    p.edit()
                        .putLong(KEY_LAST_ALARM_AT, now)
                        .putLong(KEY_LAST_STOP_AT, now)
                        .putLong(KEY_SERVER_STOP_AT, now)
                        .apply()
                    Log.w(TAG, "server says expired, hard stop")
                    hardStop(context)
                }
                return
            }

            // 未到期：用服务端到期日校正本地闹钟（自检期间不覆盖）
            if (p.getBoolean(KEY_TEST_MODE, false)) return
            val target = parseExpiryMillis(expiresOn)
            val current = deadlineMillis(context)
            if (target > 0L && kotlin.math.abs(target - current) > 60_000L) {
                p.edit().putLong(KEY_DEADLINE, target).apply()
                schedule(context, target)
                Log.i(TAG, "deadline corrected by server: $target")
            }
        } finally {
            runCatching { conn.disconnect() }
        }
    }

    private fun recordServerState(p: android.content.SharedPreferences, state: String) {
        p.edit()
            .putLong(KEY_SERVER_POLL_AT, System.currentTimeMillis())
            .putString(KEY_SERVER_STATE, state)
            .apply()
    }

    /** "2026-11-28" → 当天 23:59:59 本地时间戳；解析失败返回 0。 */
    private fun parseExpiryMillis(expiresOn: String): Long {
        val text = expiresOn.trim()
        if (text.isEmpty()) return 0L
        val datePart = text.substringBefore(' ').substringBefore('T')
        return runCatching {
            java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US)
                .parse("$datePart 23:59:59")
                ?.time ?: 0L
        }.getOrDefault(0L)
    }

    /** Dart 回到前台时读取：是否发生过「到期自动断开」，读后即清。 */
    fun consumeAutoStopped(context: Context): Boolean {
        val p = prefs(context)
        val value = runCatching { p.getBoolean(KEY_AUTO_STOPPED, false) }.getOrDefault(false)
        if (value) {
            p.edit().putBoolean(KEY_AUTO_STOPPED, false).apply()
        }
        return value
    }

    /** 供 UI/诊断使用：最近一次到期断开的原生时间戳。 */
    fun lastStopAt(context: Context): Long =
        runCatching { prefs(context).getLong(KEY_LAST_STOP_AT, 0L) }.getOrDefault(0L)

    /**
     * 自检：把到期时间改成 now + seconds，走与真实到期完全相同的闹钟 + 看门狗链路。
     * 用于 1 分钟内验证「后台到点断开」是否真的生效。
     */
    fun startSimulatedExpiry(context: Context, seconds: Long) {
        val appContext = context.applicationContext
        val now = System.currentTimeMillis()
        val target = now + seconds.coerceIn(10L, 3600L) * 1000L
        prefs(appContext).edit()
            .putLong(KEY_DEADLINE, target)
            .putBoolean(KEY_TEST_MODE, true)
            .putBoolean(KEY_AUTO_STOPPED, false)
            .putBoolean(KEY_TEST_STOPPED, false)
            .apply()
        schedule(appContext, target)
        Log.w(TAG, "simulated expiry armed at $target")
    }

    /** 自检模式下是否已完成一次「后台到点断开」，读后即清。 */
    fun consumeTestStop(context: Context): Boolean {
        val p = prefs(context)
        val value = runCatching { p.getBoolean(KEY_TEST_STOPPED, false) }.getOrDefault(false)
        if (value) {
            p.edit()
                .putBoolean(KEY_TEST_STOPPED, false)
                .putBoolean(KEY_TEST_MODE, false)
                .apply()
        }
        return value
    }

    /** 诊断信息：一眼看出到期闹钟有没有真的挂上、看门狗有没有在跑。 */
    fun statusSnapshot(context: Context): String {
        val am = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            runCatching { am?.canScheduleExactAlarms() == true }.getOrDefault(false)
        val p = prefs(context)
        val now = System.currentTimeMillis()
        val deadline = deadlineMillis(context)
        fun ts(v: Long) = if (v <= 0L) "-" else
            java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date(v))
        val remain = if (deadline > now) (deadline - now) / 1000 else -1
        return buildString {
            append("到期时间：").append(ts(deadline))
            if (remain >= 0) append("（剩 ").append(remain).append(" 秒）") else append("（已过期/未设置）")
            append("\n闹钟模式：").append(p.getString(KEY_SCHEDULE_MODE, "-") ?: "-")
            append("　精确闹钟授权：").append(if (exact) "是" else "否")
            append("\n闹钟挂载次数：").append(p.getInt(KEY_SCHEDULE_COUNT, 0))
            append("\n最近挂载：").append(ts(p.getLong(KEY_LAST_SCHEDULE_AT, 0L)))
            append("\n看门狗轮询：").append(p.getLong(KEY_WATCH_TICKS, 0L)).append(" 次")
            append("\n最近闹钟触发：").append(ts(p.getLong(KEY_LAST_ALARM_AT, 0L)))
            append("\n最近到期断开：").append(ts(p.getLong(KEY_LAST_STOP_AT, 0L)))
            append("\nDart 最近同步：").append(ts(p.getLong(KEY_DART_SYNC_AT, 0L)))
            append("\n持有唤醒锁：").append(if (wakeLock?.isHeld == true) "是" else "否")
            append("\n当前运行状态：").append(GlobalState.currentRunState)
            append("\nVPN 服务：").append(if (BettboxVpnService.isInstanceActive) "运行中" else "未运行")
            append("\n自检模式：").append(if (p.getBoolean(KEY_TEST_MODE, false)) "是" else "否")
            append("\n服务端核对：").append(ts(p.getLong(KEY_SERVER_POLL_AT, 0L)))
            append("\n服务端结论：").append(p.getString(KEY_SERVER_STATE, "-") ?: "-")
            append("\n手机时间：").append(ts(now))
        }
    }
}
