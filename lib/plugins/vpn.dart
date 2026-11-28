import 'dart:async';
import 'dart:convert';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract mixin class VpnListener {
  void onDnsChanged(String dns) {}

  void onScreenStateChanged(bool isOn) {}

  void onNetworkChanged(bool defaultChanged) {}
}

class Vpn {
  static final Vpn _instance = Vpn._internal();
  final MethodChannel methodChannel = const MethodChannel('vpn');

  Vpn._internal() {
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'gc':
          await clashLibHandler?.freeOSMemory();
          break;
        case 'closeConnections':
          unawaited(clashCore.closeConnections());
          break;
        case 'status':
          return clashLibHandler?.getRunTime() != null;
        case 'dnsChanged':
          for (final listener in _listeners) {
            listener.onDnsChanged(call.arguments as String);
          }
          break;
        case 'screenStateChanged':
          final isOn = call.arguments as bool;
          globalState.isScreenOn = isOn;
          for (final listener in _listeners) {
            listener.onScreenStateChanged(isOn);
          }
          break;
        case 'networkChanged':
          final defaultChanged = call.arguments == true;
          for (final listener in _listeners) {
            listener.onNetworkChanged(defaultChanged);
          }
          break;
        default:
      }
    });
  }

  factory Vpn() => _instance;

  final ObserverList<VpnListener> _listeners = ObserverList<VpnListener>();

  Future<bool?> start(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('start', {
      'data': jsonEncode(options),
    });
  }

  Future<bool?> stop() => methodChannel.invokeMethod<bool>('stop');

  /// 同步套餐到期时间到原生侧（原生用闹钟在后台也能按时断开）。
  ///
  /// [expiresAtMillis] 为 0 表示无到期时间（长期有效/未登录）。
  Future<bool?> setExpiryDeadline({
    required int expiresAtMillis,
    required bool expired,
  }) => methodChannel.invokeMethod<bool>('setExpiryDeadline', {
    'expiresAt': expiresAtMillis,
    'expired': expired,
  });

  /// 读取并清除「到期已自动断开」标记。
  Future<bool?> consumeExpiryAutoStop() =>
      methodChannel.invokeMethod<bool>('consumeExpiryAutoStop');

  /// 到期守护自检信息（闹钟是否挂上、看门狗是否在跑）。
  Future<String?> expiryStatus() =>
      methodChannel.invokeMethod<String>('expiryStatus');

  /// 模拟 [seconds] 秒后到期，走真实闹钟 + 看门狗链路自检后台断开。
  Future<bool?> simulateExpiry({int seconds = 60}) =>
      methodChannel.invokeMethod<bool>('simulateExpiry', {'seconds': seconds});

  /// 读取并清除「自检模式已完成后台断开」标记。
  Future<bool?> consumeExpiryTestStop() =>
      methodChannel.invokeMethod<bool>('consumeExpiryTestStop');

  Future<List<String>> getLocalIpAddresses() async {
    return await methodChannel.invokeListMethod<String>(
          'getLocalIpAddresses',
        ) ??
        const [];
  }

  Future<List<String>> getLocalGateways() async {
    return await methodChannel.invokeListMethod<String>('getLocalGateways') ??
        const [];
  }

  Future<String?> getCurrentDns() =>
      methodChannel.invokeMethod<String>('getCurrentDns');

  Future<bool> hasPhysicalNetwork() async {
    return await methodChannel.invokeMethod<bool>('hasPhysicalNetwork') ??
        false;
  }

  Future<bool?> quickResponse() =>
      methodChannel.invokeMethod<bool>('quickResponse');

  Future<bool> isSmartStopped() async {
    return await methodChannel.invokeMethod<bool>('isSmartStopped') ?? false;
  }

  Future<bool> isSmartStopOverride() async {
    return await methodChannel.invokeMethod<bool>('isSmartStopOverride') ??
        false;
  }

  Future<bool?> clearSmartStopOverride() =>
      methodChannel.invokeMethod<bool>('clearSmartStopOverride');

  Future<bool?> smartStop() => methodChannel.invokeMethod<bool>('smartStop');

  Future<bool?> smartResume(AndroidVpnOptions options) async {
    return await methodChannel.invokeMethod<bool>('smartResume', {
      'data': jsonEncode(options),
    });
  }

  Future<bool> getStatus() async {
    return await methodChannel.invokeMethod<bool>('status') ?? false;
  }

  Future<void> updateNotificationSpeed(
    String profileName,
    String speedInfo,
  ) async {
    await methodChannel.invokeMethod<void>('updateNotificationSpeed', {
      'profileName': profileName,
      'speedInfo': speedInfo,
    });
  }

  void addListener(VpnListener listener) => _listeners.add(listener);

  void removeListener(VpnListener listener) => _listeners.remove(listener);
}

Vpn? get vpn => globalState.isService ? Vpn() : null;
