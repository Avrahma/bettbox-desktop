import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 登录 token 的本地加密存储（仅 Android 生效）。
///
/// Android 侧由原生 Keystore（AES/GCM）加密后写入应用私有目录，
/// 避免 token 明文落在 SharedPreferences 中被 adb / 云备份带走。
/// 桌面端没有对应的 MethodChannel 实现，[_supported] 为 false，
/// 调用方继续走原来的 SharedPreferences 路径，行为与改动前一致。
class TokenVault {
  static const MethodChannel _channel = MethodChannel('appshub/token_vault');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 读取已加密保存的 token；没有或不支持时返回 null。
  static Future<String?> read() async {
    if (!_supported) {
      return null;
    }
    try {
      final value = await _channel.invokeMethod<String>('read');
      if (value == null || value.isEmpty) {
        return null;
      }
      return value;
    } catch (e) {
      debugPrint('TokenVault.read failed: $e');
      return null;
    }
  }

  /// 加密保存 token；失败返回 false，调用方回退到原有明文存储。
  static Future<bool> write(String value) async {
    if (!_supported) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('write', {'value': value});
      return ok ?? false;
    } catch (e) {
      debugPrint('TokenVault.write failed: $e');
      return false;
    }
  }

  static Future<void> clear() async {
    if (!_supported) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('clear');
    } catch (e) {
      debugPrint('TokenVault.clear failed: $e');
    }
  }
}
