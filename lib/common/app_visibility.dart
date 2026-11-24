import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/preferences.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter/foundation.dart';

/// 界面元素的可见性控制：
/// 1. 底部导航「配置」入口对所有用户默认隐藏，首页标题连续点击 3 次临时显示，
///    显示后 2 秒无操作自动隐藏；首页模块中的「配置」卡片仅按套餐状态决定（已购用户不隐藏）；
/// 2. 活跃连接、内存信息默认隐藏，由用户在设置中自由开关；
/// 3. 登录页的服务器地址入口默认隐藏，连续点击站点名 3 次可切换显示/隐藏；
/// 4.「配置」页的「添加配置」按钮默认隐藏，连续点击标题 3 次可切换显示/隐藏，
///    显示后超过 3 秒无操作自动隐藏。
class AppVisibility extends ChangeNotifier {
  AppVisibility._();

  static final AppVisibility instance = AppVisibility._();

  static const String _kAdvancedStats = 'app_visibility_advanced_stats';
  static const String _kToolsOther = 'app_visibility_tools_other';

  bool _showAdvancedStats = false;
  bool _toolsOtherVisible = false;

  bool _serverAddressVisible = false;
  bool _addProfileVisible = false;
  bool _initialized = false;

  int _profileTapCount = 0;
  DateTime? _profileLastTap;
  int _titleTapCount = 0;
  DateTime? _titleLastTap;
  int _toolsTapCount = 0;
  DateTime? _toolsTapLast;
  int _profilesTapCount = 0;
  DateTime? _profilesTapLast;
  Timer? _addProfileHideTimer;
  bool _navProfileVisible = false;
  Timer? _navProfileHideTimer;

  bool get showAdvancedStats => _showAdvancedStats;

  bool get profileUnlocked => hasActivePlan;

  bool get serverAddressVisible => _serverAddressVisible;

  /// 「配置」页的「添加配置」按钮是否可见，默认隐藏。
  bool get addProfileVisible => _addProfileVisible;

  /// 是否购买有效套餐。
  bool get hasActivePlan {
    final sub = AppAuth.instance.subscription;
    return sub != null && !sub.expired;
  }

  /// 「更多」页最后一栏「其他」是否显示，默认隐藏。
  bool get toolsOtherVisible => _toolsOtherVisible;

  /// 首页模块中的账户/配置卡片是否可见：仅已购买有效套餐的用户显示，
  /// 未购用户首页不展示该模块。
  bool get showProfileEntries => hasActivePlan;

  /// 底部导航「配置」入口是否可见：默认隐藏，标题连点 3 次临时显示。
  bool get navProfileVisible => _navProfileVisible;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      _showAdvancedStats = prefs?.getBool(_kAdvancedStats) ?? false;
      _toolsOtherVisible = prefs?.getBool(_kToolsOther) ?? false;
    } catch (_) {
      // 读取失败时使用默认值。
    }
    notifyListeners();
  }

  Future<void> setShowAdvancedStats(bool value) async {
    if (_showAdvancedStats == value) {
      return;
    }
    _showAdvancedStats = value;
    notifyListeners();
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setBool(_kAdvancedStats, value);
    } catch (_) {
      // 忽略持久化失败。
    }
  }

  /// 首页标题连续点击 3 次：临时显示底部导航「配置」入口，2 秒无操作自动隐藏。
  /// 已购与未购用户均默认隐藏，不做持久化。
  void tapDashboardTitle() {
    final now = DateTime.now();
    final last = _profileLastTap;
    _profileTapCount = (last != null &&
            now.difference(last) <= const Duration(milliseconds: 1500))
        ? _profileTapCount + 1
        : 1;
    _profileLastTap = now;
    if (_profileTapCount >= 3) {
      _profileTapCount = 0;
      _profileLastTap = null;
      _setNavProfileVisible(true);
      return;
    }
    if (_navProfileVisible) {
      _restartNavProfileHideTimer();
    }
  }

  void _setNavProfileVisible(bool value) {
    _navProfileHideTimer?.cancel();
    _navProfileHideTimer = null;
    if (_navProfileVisible != value) {
      _navProfileVisible = value;
      notifyListeners();
    }
    if (value) {
      _restartNavProfileHideTimer();
    }
  }

  void _restartNavProfileHideTimer() {
    _navProfileHideTimer?.cancel();
    _navProfileHideTimer = Timer(const Duration(seconds: 2), () {
      _navProfileHideTimer = null;
      if (!_navProfileVisible) {
        return;
      }
      _navProfileVisible = false;
      notifyListeners();
    });
  }

  /// 「更多」页标题连续点击 5 次：在显示与隐藏之间切换「其他」栏。
  /// 桌面端 controller 在切换页面时调用；同步安卓逻辑后配置入口不再自动隐藏，
  /// 保留此方法仅为接口兼容。
  void onPageChanged(PageLabel label) {}

  void tapToolsTitle() {
    final now = DateTime.now();
    final last = _toolsTapLast;
    _toolsTapCount = (last != null &&
            now.difference(last) <= const Duration(milliseconds: 1500))
        ? _toolsTapCount + 1
        : 1;
    _toolsTapLast = now;
    if (_toolsTapCount >= 5) {
      _toolsTapCount = 0;
      _toolsTapLast = null;
      _toolsOtherVisible = !_toolsOtherVisible;
      notifyListeners();
      unawaited(_persistToolsOther(_toolsOtherVisible));
    }
  }

  Future<void> _persistToolsOther(bool value) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setBool(_kToolsOther, value);
    } catch (_) {
      // 忽略持久化失败。
    }
  }

  /// 登录页站点名连续点击 3 次：在显示与隐藏之间切换服务器地址入口。
  void tapLoginTitle() {
    final now = DateTime.now();
    final last = _titleLastTap;
    _titleTapCount = (last != null &&
            now.difference(last) <= const Duration(milliseconds: 1500))
        ? _titleTapCount + 1
        : 1;
    _titleLastTap = now;
    if (_titleTapCount >= 3) {
      _titleTapCount = 0;
      _titleLastTap = null;
      _serverAddressVisible = !_serverAddressVisible;
      notifyListeners();
    }
  }

  /// 「配置」页标题连续点击 3 次：在显示与隐藏之间切换「添加配置」按钮。
  /// 显示后若 3 秒内无任何点击，自动恢复隐藏。
  void tapProfilesTitle() {
    final now = DateTime.now();
    final last = _profilesTapLast;
    _profilesTapCount = (last != null &&
            now.difference(last) <= const Duration(milliseconds: 1500))
        ? _profilesTapCount + 1
        : 1;
    _profilesTapLast = now;
    if (_profilesTapCount >= 3) {
      _profilesTapCount = 0;
      _profilesTapLast = null;
      _setAddProfileVisible(!_addProfileVisible);
      return;
    }
    // 按钮已显示时，任何点击都重新开始 3 秒倒计时。
    if (_addProfileVisible) {
      _restartAddProfileHideTimer();
    }
  }

  void _setAddProfileVisible(bool value) {
    _addProfileHideTimer?.cancel();
    _addProfileHideTimer = null;
    if (_addProfileVisible != value) {
      _addProfileVisible = value;
      notifyListeners();
    }
    if (value) {
      _restartAddProfileHideTimer();
    }
  }

  void _restartAddProfileHideTimer() {
    _addProfileHideTimer?.cancel();
    _addProfileHideTimer = Timer(const Duration(seconds: 3), () {
      _addProfileHideTimer = null;
      if (!_addProfileVisible) {
        return;
      }
      _addProfileVisible = false;
      notifyListeners();
    });
  }
}
