import 'dart:io';

import 'package:bett_box/common/print.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// 设备身份：用于服务端「套餐同时在线设备数」限制。
///
/// 取值策略：优先系统级稳定标识（Android ANDROID_ID / Windows MachineGuid /
/// macOS IOPlatformUUID / iOS identifierForVendor），拿不到时退化为
/// 「平台-主机名」的稳定指纹。结果在进程内缓存，避免重复调用原生接口。
class DeviceIdentity {
  const DeviceIdentity._(this.id, this.platform, this.name);

  final String id;
  final String platform;
  final String name;

  static DeviceIdentity? _cached;
  static Future<DeviceIdentity>? _inflight;

  static Future<DeviceIdentity> load() {
    final cached = _cached;
    if (cached != null) {
      return Future<DeviceIdentity>.value(cached);
    }
    return _inflight ??= _resolve().then((value) {
      _cached = value;
      _inflight = null;
      return value;
    }).catchError((Object e) {
      _inflight = null;
      commonPrint.warn('DeviceIdentity resolve failed: $e');
      final fallback = DeviceIdentity._(
        _fallbackId(),
        _platformName(),
        _platformName(),
      );
      _cached = fallback;
      return fallback;
    });
  }

  static Future<DeviceIdentity> _resolve() async {
    final plugin = DeviceInfoPlugin();
    final platform = _platformName();

    if (Platform.isAndroid) {
      final info = await plugin.androidInfo;
      return DeviceIdentity._(
        _normalizeId(info.id, 'android'),
        platform,
        _asciiSafe(info.model, 'Android'),
      );
    }
    if (Platform.isIOS) {
      final info = await plugin.iosInfo;
      return DeviceIdentity._(
        _normalizeId(info.identifierForVendor, 'ios'),
        platform,
        _asciiSafe(info.name, 'iPhone'),
      );
    }
    if (Platform.isWindows) {
      final info = await plugin.windowsInfo;
      return DeviceIdentity._(
        _normalizeId(info.deviceId, 'win'),
        platform,
        _asciiSafe(info.computerName, 'Windows'),
      );
    }
    if (Platform.isMacOS) {
      final info = await plugin.macOsInfo;
      return DeviceIdentity._(
        _normalizeId(info.systemGUID, 'mac'),
        platform,
        _asciiSafe(info.computerName, 'macOS'),
      );
    }
    if (Platform.isLinux) {
      final info = await plugin.linuxInfo;
      return DeviceIdentity._(
        _normalizeId(info.machineId, 'linux'),
        platform,
        _asciiSafe(info.prettyName, 'Linux'),
      );
    }
    return DeviceIdentity._(_fallbackId(), platform, platform);
  }

  static String _platformName() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 统一成「平台-原始ID」形式，避免不同平台 ID 撞车；过短或空的 ID 走兜底。
  static String _normalizeId(String? raw, String prefix) {
    final value = (raw ?? '').trim();
    if (value.length < 4) {
      return _fallbackId();
    }
    return '$prefix-$value';
  }

  static String _fallbackId() {
    final host = Platform.localHostname.trim();
    return '${_platformName()}-${host.isEmpty ? 'unknown' : host}';
  }

  /// HTTP 头只能携带可打印 ASCII，中文设备名会直接导致请求失败，这里做清洗。
  static String _asciiSafe(String input, String fallback) {
    final cleaned = input.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    return cleaned.isEmpty ? fallback : cleaned;
  }
}
