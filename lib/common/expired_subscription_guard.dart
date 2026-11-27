import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/pages/shop.dart';
import 'package:bett_box/state.dart';
import 'package:material_ui/material_ui.dart';

/// 已过期套餐的启动拦截。
///
/// 登录用户的套餐到期后点击「启动连接」，不再直接拉起内核，
/// 而是弹窗提示「当前套餐已过期」，并提供「续费」「退出」两个动作：
/// - 续费：跳转套餐中心
/// - 退出：仅关闭弹窗，停留在首页（不退出登录）
class ExpiredSubscriptionGuard {
  const ExpiredSubscriptionGuard._();

  /// 当前登录账号的主套餐是否已过期。未登录或套餐信息缺失时返回 false。
  static bool get isExpired {
    if (!AppAuth.instance.loggedIn) return false;
    final sub = AppAuth.instance.subscription;
    return sub != null && sub.expired;
  }

  /// 过期则弹窗拦截。返回 true 表示本次启动已被拦下。
  static Future<bool> intercept() async {
    if (!isExpired) return false;

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
      final navigator = globalState.navigatorKey.currentState;
      if (navigator != null) {
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const ShopPage()),
          ),
        );
      }
    }
    return true;
  }
}
