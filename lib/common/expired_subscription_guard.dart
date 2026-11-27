import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/pages/shop.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';

/// 套餐到期的启动拦截与自动断开。
///
/// 两个动作：
/// 1. 启动拦截：套餐到期后点击「启动连接」不再拉起内核，弹窗提示
///    「当前套餐已过期」，提供「续费」「退出」。
/// 2. 到期巡检（[startWatcher]）：已处于连接状态时，套餐到期会主动断开
///    连接并提示，避免「到期后仍能一直用」。
class ExpiredSubscriptionGuard {
  const ExpiredSubscriptionGuard._();

  /// 到期巡检周期。套餐按天/按时到期，分钟级巡检足够及时。
  static const Duration _watchInterval = Duration(seconds: 30);

  /// 套餐信息刷新间隔。本地只有缓存的过期标记，连接期间长时间不刷新
  /// 会感知不到服务端侧的到期（运营手动停用、提前到期等）。
  static const Duration _refreshInterval = Duration(minutes: 10);

  static Timer? _timer;
  static DateTime? _lastRefreshAt;
  static String _notifiedKey = '';
  static bool _handling = false;

  /// 服务端下发的过期标记。未登录或套餐信息缺失时返回 false。
  static bool get isExpired {
    if (!AppAuth.instance.loggedIn) return false;
    final sub = AppAuth.instance.subscription;
    return sub != null && sub.expired;
  }

  /// 套餐到期时间点。只给日期时按当天 23:59:59 计。
  static DateTime? get expiresAt {
    final sub = AppAuth.instance.subscription;
    if (sub == null) return null;
    final raw = sub.expiresOn.trim();
    if (raw.isEmpty) return null;
    final normalized = raw.replaceAll('/', '-');
    DateTime? parsed = DateTime.tryParse(normalized);
    parsed ??= normalized.length >= 10
        ? DateTime.tryParse(normalized.substring(0, 10))
        : null;
    if (parsed == null) return null;
    if (!normalized.contains(':')) {
      parsed = DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59);
    }
    return parsed;
  }

  /// 本地兜底判定：服务端刷新滞后时，按 expires_on 也已到期。
  static bool get isExpiredLocally {
    if (!AppAuth.instance.loggedIn) return false;
    final sub = AppAuth.instance.subscription;
    if (sub == null) return false;
    // days_left < 0 表示长期有效
    if (!sub.expired && sub.daysLeft < 0) return false;
    final at = expiresAt;
    return at != null && DateTime.now().isAfter(at);
  }

  /// 是否已到期（服务端标记或本地日期兜底）。
  static bool get isExpiredNow => isExpired || isExpiredLocally;

  /// 启动到期巡检。应用启动后调用一次即可。
  static void startWatcher() {
    if (_timer != null) return;
    _timer = Timer.periodic(_watchInterval, (_) => unawaited(_tick()));
    unawaited(_tick());
  }

  /// 立即巡检一次（回到前台时调用，弥补后台定时器被系统挂起）。
  static void checkNow() => unawaited(_tick());

  static Future<void> _tick() async {
    if (_handling) return;
    if (!AppAuth.instance.loggedIn) return;
    _handling = true;
    try {
      await _refreshIfNeeded();
      if (!isExpiredNow) return;
      if (!globalState.isStart) return;
      // 强制停核并清空代理运行态（节点/分组），避免断开后代理页仍显示线路
      await globalState.appController.shutdownAndClearProxies();
      // 停核过程中可能仍有 in-flight 的节点读取回写，稍后再清一次兜底
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 800), () {
          globalState.appController.clearProxyRuntime();
        }),
      );
      await _notifyAutoStopped();
    } catch (_) {
      // 巡检异常不打断主流程，下一轮继续
    } finally {
      _handling = false;
    }
  }

  static Future<void> _refreshIfNeeded() async {
    final now = DateTime.now();
    final last = _lastRefreshAt;
    if (last != null && now.difference(last) < _refreshInterval) return;
    _lastRefreshAt = now;
    await AppAuth.instance.refresh();
  }

  /// 到期自动断开后的提示。同一套餐只提示一次，避免反复骚扰。
  static Future<void> _notifyAutoStopped() async {
    final sub = AppAuth.instance.subscription;
    final key = '${sub?.id ?? 0}|${sub?.expiresOn ?? ''}';
    if (_notifiedKey == key) return;
    _notifiedKey = key;

    final expiresOn = sub?.expiresOn ?? '';
    final result = await globalState.showMessage(
      title: '当前套餐已过期',
      message: TextSpan(
        text: expiresOn.isEmpty
            ? '套餐已到期，连接已自动断开，续费后可继续使用。'
            : '套餐已于 $expiresOn 到期，连接已自动断开，续费后可继续使用。',
      ),
      cancelText: '退出',
      confirmText: '续费',
    );
    if (result == true) {
      _openShop();
    }
  }

  /// 过期则弹窗拦截。返回 true 表示本次启动已被拦下。
  static Future<bool> intercept() async {
    if (!isExpiredNow) return false;

    final expiresOn = AppAuth.instance.subscription?.expiresOn ?? '';
    final result = await globalState.showMessage(
      title: '当前套餐已过期',
      message: TextSpan(
        text: expiresOn.isEmpty
            ? '套餐已到期，续费后可继续使用。'
            : '套餐已于 $expiresOn 到期，续费后可继续使用。',
      ),
      cancelText: '退出',
      confirmText: '续费',
    );

    if (result == true) {
      _openShop();
    }
    return true;
  }

  static void _openShop() {
    final navigator = globalState.navigatorKey.currentState;
    if (navigator != null) {
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const ShopPage()),
        ),
      );
    }
  }
}
