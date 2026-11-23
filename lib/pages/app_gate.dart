import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/app_subscription_guard.dart';
import 'package:bett_box/common/app_visibility.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/home.dart';
import 'package:bett_box/pages/login.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';

/// 应用入口闸门：未登录显示登录页，已登录进入主界面并自动同步订阅。
class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> with WidgetsBindingObserver {
  bool _ready = false;
  bool _wasLoggedIn = false;
  bool _syncing = false;
  bool _syncPending = false;
  bool _refreshing = false;
  String? _ownerKey;
  String _subscriptionSignature = '';
  Timer? _retryTimer;
  int _retryRound = 0;
  Timer? _emptySubTimer;
  int _emptySubRound = 0;
  final List<Timer> _resumeTimers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppAuth.instance.addListener(_onAuthChanged);
    unawaited(AppVisibility.instance.init());
    unawaited(_boot());
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _emptySubTimer?.cancel();
    for (final timer in _resumeTimers) {
      timer.cancel();
    }
    _resumeTimers.clear();
    WidgetsBinding.instance.removeObserver(this);
    AppAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !AppAuth.instance.loggedIn) {
      return;
    }
    // 从站点购买/续费页返回时，支付结果可能尚未落库，追加几次延迟刷新。
    for (final timer in _resumeTimers) {
      timer.cancel();
    }
    _resumeTimers.clear();
    unawaited(_refreshAndSync());
    for (final seconds in const [5, 15]) {
      _resumeTimers.add(
        Timer(Duration(seconds: seconds), () {
          if (mounted && AppAuth.instance.loggedIn) {
            unawaited(_refreshAndSync());
          }
        }),
      );
    }
  }

  /// 当前账户订阅集合的指纹，用于识别套餐购买、续费、链接变更等。
  String _currentSignature() {
    final owner = _currentOwnerKey();
    if (owner == null) {
      return '';
    }
    final urls = _allowedUrls().toList()..sort();
    return '$owner|${urls.join('|')}';
  }

  Future<void> _boot() async {
    await AppAuth.instance.restore();
    if (!mounted) {
      return;
    }
    _wasLoggedIn = AppAuth.instance.loggedIn;
    _ownerKey = _currentOwnerKey();
    setState(() => _ready = true);
    if (_wasLoggedIn) {
      unawaited(_refreshAndSync());
    } else {
      // 未登录也必须清空上一账户残留的订阅配置。
      final ids = globalState.config.profiles.map((item) => item.id).toList();
      unawaited(
        _waitAppReady().then(
          (_) => AppSubscriptionGuard.instance.purgeAllOnLogout(
            profileIds: ids,
          ),
        ),
      );
    }
  }

  /// 账户归属标识：优先邮箱，缺失时退化为账户 ID。
  String? _currentOwnerKey() {
    final data = AppAuth.instance.account;
    if (data == null) {
      return null;
    }
    final email = data.account.email.trim();
    if (email.isNotEmpty) {
      return email;
    }
    if (data.account.id > 0) {
      return 'id:${data.account.id}';
    }
    return null;
  }

  /// 当前账户仍有效的订阅链接集合。
  Set<String> _allowedUrls() {
    final data = AppAuth.instance.account;
    final urls = <String>{};
    if (data == null) {
      return urls;
    }
    for (final item in data.subscriptions) {
      if (item.subUrl.isNotEmpty) {
        urls.add(item.subUrl);
      }
    }
    final primary = data.primary;
    if (primary != null && primary.subUrl.isNotEmpty) {
      urls.add(primary.subUrl);
    }
    return urls;
  }

  void _onAuthChanged() {
    if (!mounted) {
      return;
    }
    final loggedIn = AppAuth.instance.loggedIn;
    if (loggedIn) {
      final key = _currentOwnerKey();
      final signature = _currentSignature();
      final previousOwner = _ownerKey;
      final switchedAccount =
          _wasLoggedIn &&
          previousOwner != null &&
          key != null &&
          key != previousOwner;
      final ownerChanged = !_wasLoggedIn || switchedAccount;
      final subscriptionChanged = signature != _subscriptionSignature;
      _wasLoggedIn = true;
      _ownerKey = key;
      if (switchedAccount) {
        // 直接切换账户（未先退出登录）：先按上一个账户清掉其配置，
        // 避免新账户登录后仍能看到上一个账户的代理线路。
        final ids = globalState.config.profiles
            .map((item) => item.id)
            .toList();
        unawaited(
          _waitAppReady().then(
            (_) => AppSubscriptionGuard.instance.purgeAllOnLogout(
              profileIds: ids,
              previousOwner: previousOwner,
            ),
          ),
        );
      }
      // 刷新过程中数据会多次变更，由刷新流程自行收敛，避免重复触发。
      if (_refreshing) {
        return;
      }
      if (ownerChanged || subscriptionChanged) {
        _subscriptionSignature = signature;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_refreshAndSync());
          }
        });
      }
    } else {
      _wasLoggedIn = false;
      final oldOwnerKey = _ownerKey;
      _ownerKey = null;
      _subscriptionSignature = '';
      // 退出登录：清除登出前已存在的订阅配置（含手动添加），
      // 保证后续登录的未购套餐账户不会看到上一个账户的线路。
      final previousOwner = oldOwnerKey;
      final ids = globalState.config.profiles.map((item) => item.id).toList();
      unawaited(
        _waitAppReady().then(
          (_) => AppSubscriptionGuard.instance.purgeAllOnLogout(
            profileIds: ids,
            previousOwner: previousOwner,
          ),
        ),
      );
      _ensureSignedOutUi();
    }
  }

  /// 退出登录后强制回到根路由并刷新界面。
  ///
  /// 桌面端窗口层级较多，退出瞬间可能仍有页面/弹窗压在栈顶，
  /// 或首页画面被快照缓存，导致界面停留在“退出登录”时的旧画面。
  void _ensureSignedOutUi() {
    if (!mounted) {
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || AppAuth.instance.loggedIn) {
        return;
      }
      final navigator = globalState.navigatorKey.currentState;
      navigator?.popUntil((route) => route.isFirst);
      setState(() {});
    });
  }

  Future<void> _refreshAndSync() async {
    if (_refreshing || !AppAuth.instance.loggedIn) {
      return;
    }
    _refreshing = true;
    try {
      // 先记下当前指纹，refresh 内部的 notifyListeners 不会再次触发同步。
      _subscriptionSignature = _currentSignature();
      final valid = await AppAuth.instance.refresh();
      if (!valid) {
        await AppAuth.instance.logout();
        return;
      }
      if (!AppAuth.instance.loggedIn) {
        return;
      }
      _subscriptionSignature = _currentSignature();
    } finally {
      _refreshing = false;
    }
    await _syncProfile();
  }

  /// 把账号当前生效的订阅导入为配置并启用，同时清除其他账户的订阅。
  Future<void> _syncProfile() async {
    if (_syncing) {
      _syncPending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _syncPending = false;
        bool ok;
        try {
          ok = await _syncProfileOnce();
        } catch (e) {
          commonPrint.warn('AppGate sync failed: $e');
          ok = false;
          _scheduleRetry();
        }
        if (ok) {
          _retryRound = 0;
          _retryTimer?.cancel();
        }
      } while (_syncPending);
    } finally {
      _syncing = false;
    }
  }

  /// 执行一次完整同步，返回是否无需再重试。
  Future<bool> _syncProfileOnce() async {
    await _waitAppReady();
    if (!AppAuth.instance.loggedIn) {
      return true;
    }
    final owner = _currentOwnerKey();
    final allowedUrls = _allowedUrls();
    if (owner == null) {
      return true;
    }
    // 先做账户隔离：删除不属于当前账户的订阅配置；隔离失败不应阻塞导入。
    final sub = AppAuth.instance.subscription;
    final hasSubscription = sub != null && sub.subUrl.trim().isNotEmpty;
    try {
      await AppSubscriptionGuard.instance.enforce(
        email: owner,
        allowedUrls: allowedUrls,
        // 账号数据里没有订阅时（多为离线快照），保留本账户已导入的配置。
        dropCurrentOwner: hasSubscription,
      );
    } catch (e) {
      commonPrint.warn('AppGate enforce failed: $e');
    }
    if (!AppAuth.instance.loggedIn || _currentOwnerKey() != owner) {
      return true;
    }
    if (!hasSubscription) {
      // 账号没有任何有效套餐（未购买 / 全部过期）：清空本机全部配置，
      // 避免未购买账户沿用上一个账户或历史遗留的线路节点。
      final account = AppAuth.instance.account;
      final noValidSub =
          account != null &&
          account.subscriptions.every(
            (item) => item.expired || item.subUrl.trim().isEmpty,
          );
      if (noValidSub) {
        try {
          await AppSubscriptionGuard.instance.purgeAllOnLogout();
        } catch (e) {
          commonPrint.warn('AppGate purge on empty sub failed: $e');
        }
      }
      // 冷启动时首个刷新请求可能因网络未就绪失败，稍后重新拉取账号数据。
      _scheduleEmptySubRetry();
      return true;
    }
    final url = sub.subUrl.trim();
    Profile? existing;
    for (final item in globalState.config.profiles) {
      if (item.url.trim() == url) {
        existing = item;
        break;
      }
    }
    if (existing != null) {
      _emptySubTimer?.cancel();
      _emptySubRound = 0;
      await AppSubscriptionGuard.instance.recordOwner(existing.id, owner);
      await globalState.appController.addProfile(existing, activate: true);
      return true;
    }
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (!AppAuth.instance.loggedIn || _currentOwnerKey() != owner) {
        return true;
      }
      try {
        final label = sub.planName.isEmpty ? '我的订阅' : sub.planName;
        final profile = await Profile.normal(url: url, label: label).update();
        await globalState.appController.addProfile(profile, activate: true);
        final added = globalState.config.profiles.any(
          (item) => item.id == profile.id || item.url.trim() == url,
        );
        if (!added) {
          throw StateError('profile not persisted');
        }
        await AppSubscriptionGuard.instance.recordOwner(profile.id, owner);
        _emptySubTimer?.cancel();
        _emptySubRound = 0;
        return true;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
      }
    }
    commonPrint.warn('AppGate sync profile failed: $lastError');
    _scheduleRetry();
    return false;
  }

  /// 导入失败（如订阅尚未生成、网络抖动）时稍后重试。
  void _scheduleRetry() {
    if (_retryRound >= 5) {
      return;
    }
    _retryRound++;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || !AppAuth.instance.loggedIn) {
        return;
      }
      unawaited(_syncProfile());
    });
  }

  /// 账号数据里暂时没有可用订阅时，重新拉取账号数据（应对冷启动网络未就绪）。
  void _scheduleEmptySubRetry() {
    if (_emptySubRound >= 4) {
      return;
    }
    _emptySubRound++;
    _emptySubTimer?.cancel();
    _emptySubTimer = Timer(Duration(seconds: 8 * _emptySubRound), () {
      if (!mounted || !AppAuth.instance.loggedIn) {
        return;
      }
      unawaited(_refreshAndSync());
    });
  }

  /// 等待主控制器完成初始化，避免新增的配置被启动流程覆盖。
  Future<void> _waitAppReady() async {
    for (var attempt = 0; attempt < 900; attempt++) {
      try {
        if (globalState.appController.ref.read(initProvider)) {
          return;
        }
      } catch (_) {
        // 控制器尚未就绪，继续等待。
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppAuth.instance,
      builder: (context, _) {
        if (!_ready) {
          return const _GateSplash();
        }
        if (!AppAuth.instance.loggedIn) {
          return const LoginPage();
        }
        // 桌面端不使用路由快照：窗口层级与快照缓存会让退出/切换时
        // 残留旧画面，直接返回真实页面可确保状态即时刷新。
        if (system.isDesktop) {
          return const HomePage();
        }
        return const RouteSnapshot(child: HomePage());
      },
    );
  }
}

class _GateSplash extends StatelessWidget {
  const _GateSplash();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: AppIcon(
                Icons.shield_outlined,
                size: 34,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 18),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
