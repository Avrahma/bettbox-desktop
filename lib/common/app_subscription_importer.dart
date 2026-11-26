import 'dart:io';
import 'dart:typed_data';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/app_subscription_guard.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 账号订阅导入结果。
class AppImportResult {
  const AppImportResult._({
    required this.ok,
    required this.noSubscription,
    this.message,
  });

  /// 导入（或复用已有配置）成功。
  const AppImportResult.success()
    : this._(ok: true, noSubscription: false);

  /// 账号当前没有任何可用订阅链接（未购买 / 全部失效），不是错误。
  const AppImportResult.empty()
    : this._(ok: false, noSubscription: true);

  /// 有订阅链接但导入失败，[message] 可直接展示给用户。
  const AppImportResult.failed(String message)
    : this._(ok: false, noSubscription: false, message: message);

  final bool ok;
  final bool noSubscription;
  final String? message;
}

/// 把账号当前套餐对应的订阅链接导入为本地配置并启用。
///
/// 设计目标是「可诊断、可自愈」：
/// 1. 账号数据里没有订阅时先主动刷新一次账号数据；
/// 2. 逐个尝试账号下所有有效链接（primary 优先，其次未过期、到期时间靠后）；
/// 3. 已有同链接配置时直接复用并启用，不重复下载；
/// 4. 常规下载失败后改用强制直连（绕过代理）再试一次；
/// 5. 内核校验失败时退化为不校验导入，避免节点过期字段导致整条链路失败；
/// 6. 失败时返回可读原因（含 HTTP 状态码），供界面提示与用户反馈。
class AppSubscriptionImporter {
  const AppSubscriptionImporter._();

  static const Duration _readyTimeout = Duration(seconds: 30);

  /// 等待主控制器初始化，避免导入的配置被启动流程覆盖。
  static Future<void> _waitAppReady() async {
    final deadline = DateTime.now().add(_readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
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

  /// 账户归属标识：优先邮箱，缺失时退化为账户 ID。
  static String? _ownerKey() {
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

  /// 账号下可尝试的订阅，primary 优先，其余未过期优先、到期时间靠后优先。
  static List<AppSubscription> _candidates() {
    final data = AppAuth.instance.account;
    if (data == null) {
      return const [];
    }
    final result = <AppSubscription>[];
    final seen = <String>{};
    void push(AppSubscription? item) {
      final url = item?.subUrl.trim() ?? '';
      if (item == null || url.isEmpty || !seen.add(url)) {
        return;
      }
      result.add(item);
    }

    push(data.primary);
    final rest = data.subscriptions.toList()
      ..sort((a, b) {
        final expiredCompare = (a.expired ? 1 : 0).compareTo(b.expired ? 1 : 0);
        if (expiredCompare != 0) {
          return expiredCompare;
        }
        return b.daysLeft.compareTo(a.daysLeft);
      });
    for (final item in rest) {
      push(item);
    }
    return result;
  }

  /// 强制直连下载订阅内容，绕开可能尚未就绪的内核代理。
  static Future<Uint8List> _downloadDirect(String url) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 40),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback = (_, _, _) => true;
        client.connectionTimeout = const Duration(seconds: 20);
        client.userAgent = globalState.ua;
        return client;
      },
    );
    final response = await dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null || data.isEmpty) {
      throw const FormatException('订阅内容为空');
    }
    return Uint8List.fromList(data);
  }

  static String _describe(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 404 || code == 410) {
        return '订阅链接已失效（HTTP $code），请在套餐中心重新获取';
      }
      if (code == 403 || code == 401) {
        return '订阅链接无访问权限（HTTP $code）';
      }
      if (code != null) {
        return '下载订阅失败（HTTP $code）';
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '下载订阅超时，请检查网络后重试';
        case DioExceptionType.connectionError:
          return '无法连接订阅服务器，请检查网络后重试';
        default:
          break;
      }
      return '下载订阅失败：${error.message ?? error.type.name}';
    }
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    if (text.isEmpty) {
      return '订阅导入失败（未知原因）';
    }
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  /// 执行一次导入。无论成功失败都不会抛出异常。
  static Future<AppImportResult> import({bool activate = true}) async {
    if (!AppAuth.instance.loggedIn) {
      return const AppImportResult.empty();
    }
    await _waitAppReady();
    if (!AppAuth.instance.loggedIn) {
      return const AppImportResult.empty();
    }
    final owner = _ownerKey();
    if (owner == null) {
      return const AppImportResult.empty();
    }
    var candidates = _candidates();
    if (candidates.isEmpty) {
      try {
        await AppAuth.instance.refresh();
      } catch (_) {
        // 刷新失败继续用本地数据判断。
      }
      if (!AppAuth.instance.loggedIn) {
        return const AppImportResult.empty();
      }
      candidates = _candidates();
    }
    if (candidates.isEmpty) {
      return const AppImportResult.empty();
    }
    final errors = <String>[];
    for (final sub in candidates) {
      if (!AppAuth.instance.loggedIn) {
        return const AppImportResult.empty();
      }
      final url = sub.subUrl.trim();
      // 已存在同一链接的配置：直接启用，避免重复下载。
      Profile? existing;
      for (final item in globalState.config.profiles) {
        if (item.url.trim() == url) {
          existing = item;
          break;
        }
      }
      if (existing != null) {
        try {
          await globalState.appController.addProfile(
            existing,
            activate: activate,
          );
          await AppSubscriptionGuard.instance.recordOwner(existing.id, owner);
          return const AppImportResult.success();
        } catch (e) {
          errors.add(_describe(e));
          continue;
        }
      }
      final label = sub.planName.trim().isEmpty ? '我的订阅' : sub.planName.trim();
      // 先走内核/系统代理下载；失败后退化为强制直连下载。
      for (final mode in const ['normal', 'direct']) {
        for (final validate in const [true, false]) {
          try {
            final profile = Profile.normal(url: url, label: label);
            final imported = mode == 'direct'
                ? await profile.saveFile(
                    await _downloadDirect(url),
                    validate: validate,
                  )
                : await profile.update(validate: validate);
            await globalState.appController.addProfile(
              imported,
              activate: activate,
            );
            final added = globalState.config.profiles.any(
              (item) => item.id == imported.id || item.url.trim() == url,
            );
            if (!added) {
              throw StateError('配置保存失败');
            }
            await AppSubscriptionGuard.instance.recordOwner(
              imported.id,
              owner,
            );
            return const AppImportResult.success();
          } catch (e) {
            errors.add(_describe(e));
            if (!AppAuth.instance.loggedIn) {
              return const AppImportResult.empty();
            }
          }
        }
      }
    }
    final message = errors.isEmpty ? '订阅导入失败（未知原因）' : errors.first;
    commonPrint.warn('AppSubscriptionImporter failed: $message');
    return AppImportResult.failed(message);
  }
}
