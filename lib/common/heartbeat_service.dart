import 'dart:async';
import 'dart:io';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/print.dart';
import 'package:bett_box/common/system.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

/// 设备心跳调度器（独立于 UI 层的全局单例）。
///
/// 服务端按「最近 5 分钟内有活动」判定设备在线，本服务负责把本机标记为在线：
/// - 冷启动已登录 / 登录成功 → 立即发一次；
/// - 前台 → 每 90s 一次（5 分钟窗口留足冗余）；
/// - 回到前台（resumed）→ 立即补发并重建定时器；
/// - 后台（Android）/窗口最小化 → 停发；桌面端窗口失焦降频到 5 分钟保活；
/// - 退出登录 / 切换账号 → 取消定时器（名额释放走已有的 /api/app/logout）。
///
/// 防抖与退避：上一个请求未返回时跳过本轮；连续失败按 90s → 120s → 180s 递增，
/// 成功后复位；网络类错误完全静默，不弹窗、不 toast。
class HeartbeatService with WidgetsBindingObserver {
  HeartbeatService._();

  static final HeartbeatService instance = HeartbeatService._();

  /// 前台心跳间隔：服务端在线窗口 5 分钟，90s 留足冗余。
  static const Duration foregroundInterval = Duration(seconds: 90);

  /// 桌面端窗口最小化后的保活间隔。
  static const Duration desktopIdleInterval = Duration(minutes: 5);

  static const Duration _retry120 = Duration(seconds: 120);
  static const Duration _retry180 = Duration(seconds: 180);

  bool _attached = false;
  Timer? _timer;
  bool _inflight = false;
  int _failureStreak = 0;

  /// 被服务端踢下线 / 超出名额后置位，避免任何自动重启继续打服务端。
  bool _halted = false;

  String? _lastToken;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// 内部状态，仅用于排查（不驱动任何 UI）。
  int onlineDevices = 0;
  int usedDevices = 0;
  int limit = 0;

  bool get running => _timer != null;

  /// 绑定生命周期与登录态监听。重复调用无副作用，应在 App 启动时调用一次。
  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    AppAuth.instance.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (!AppAuth.instance.loggedIn || _halted) {
      _cancelTimer();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      // 回到前台：取消旧定时器，立即补发一次再按前台间隔续跑。
      _failureStreak = 0;
      _restart(immediate: true, interval: foregroundInterval);
      return;
    }
    if (system.isDesktop) {
      // 桌面端窗口失焦/最小化：降频保活，正常运行时仍保持 90s。
      _restart(immediate: false, interval: desktopIdleInterval);
      return;
    }
    // Android / iOS 必须停发，否则会被系统限流。
    _cancelTimer();
  }

  /// 登录态变化（登录成功、退出登录、切换账号）时同步调度状态。
  void _onAuthChanged() {
    final token = AppAuth.instance.token;
    if (token != _lastToken) {
      _lastToken = token;
      // 新账号/重新登录：清掉上一次的停机与退避状态。
      _halted = false;
      _failureStreak = 0;
    }
    final loggedIn = AppAuth.instance.loggedIn;
    if (!loggedIn) {
      _cancelTimer();
      return;
    }
    if (_halted) {
      return;
    }
    if (_timer != null) {
      // 已在跑：不因无关的 notifyListeners 追加请求。
      return;
    }
    if (_lifecycle != AppLifecycleState.resumed) {
      if (!system.isDesktop) {
        return;
      }
      _restart(immediate: false, interval: desktopIdleInterval);
      return;
    }
    _restart(immediate: true, interval: foregroundInterval);
  }

  /// 登录成功后由调用方可显式触发（与监听器等价，幂等）。
  void onLoggedIn() {
    _halted = false;
    _failureStreak = 0;
    _lastToken = AppAuth.instance.token;
    _onAuthChanged();
  }

  void _restart({required bool immediate, required Duration interval}) {
    _cancelTimer();
    if (!AppAuth.instance.loggedIn || _halted) {
      return;
    }
    _schedule(interval);
    if (immediate) {
      unawaited(_tick());
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_tick());
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 下一次请求的间隔：成功 90s；连续失败 120s、最长 180s。
  Duration get _nextDelay {
    switch (_failureStreak) {
      case 0:
        return _lifecycle == AppLifecycleState.resumed || !system.isDesktop
            ? foregroundInterval
            : desktopIdleInterval;
      case 1:
        return _retry120;
      default:
        return _retry180;
    }
  }

  Future<void> _tick() async {
    if (!AppAuth.instance.loggedIn || _halted) {
      return;
    }
    if (_inflight) {
      // 上一轮还没回来：跳过本轮，不叠加请求。
      _schedule(_nextDelay);
      return;
    }
    _inflight = true;
    try {
      final result = await AppAuth.instance.heartbeat();
      if (result.kicked) {
        _halt('该设备已被移出登录状态，请重新登录', '');
        return;
      }
      if (result.limitReached) {
        _halt('该账号已在其他设备登录，请重新登录时选择「强制退出其他设备」', '');
        return;
      }
      if (result.tokenInvalid) {
        _halt('登录已失效，请重新登录', '');
        return;
      }
      // 200：只更新内部状态，静默。
      _failureStreak = 0;
      onlineDevices = result.onlineDevices;
      usedDevices = result.usedDevices;
      limit = result.limit;
    } on SocketException {
      _failureStreak++;
    } on TimeoutException {
      _failureStreak++;
    } on DioException {
      _failureStreak++;
    } catch (e) {
      _failureStreak++;
      commonPrint.debug('Heartbeat failed: $e');
    } finally {
      _inflight = false;
    }
    if (AppAuth.instance.loggedIn && !_halted) {
      _schedule(_nextDelay);
    }
  }

  /// 服务端判定本机不能再继续心跳：停表、清本地登录态并回登录页。
  void _halt(String fallbackNotice, String serverMessage) {
    _halted = true;
    _cancelTimer();
    final text = serverMessage.trim().isEmpty
        ? fallbackNotice
        : serverMessage.trim();
    unawaited(AppAuth.instance.forceLogout(text));
  }

  /// 退出登录时调用：停表并清除停机标记，供下一次登录重新开始。
  void onLoggedOut() {
    _cancelTimer();
    _halted = false;
    _failureStreak = 0;
    _inflight = false;
    _lastToken = null;
  }

  void dispose() {
    _cancelTimer();
    if (_attached) {
      WidgetsBinding.instance.removeObserver(this);
      AppAuth.instance.removeListener(_onAuthChanged);
      _attached = false;
    }
  }
}
