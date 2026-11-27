import 'dart:async';
import 'dart:convert';
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
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 25),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback = (_, _, _) => true;
        client.connectionTimeout = const Duration(seconds: 12);
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

  // ---------------------------------------------------------------------------
  // 多套餐并存：一个套餐对应一个本地配置，导入后互不覆盖。
  // ---------------------------------------------------------------------------

  /// 套餐实例 → 本地配置 ID 的映射（prefs 持久化）。
  static const String _kPlanMap = 'app_managed_profile_plans';

  static String _planKeyOf(AppSubscription sub) =>
      sub.id > 0 ? 'p${sub.id}' : 'u:${sub.subUrl.trim()}';

  static String _planLabelOf(AppSubscription sub) {
    final name = sub.planName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return sub.id > 0 ? '套餐 ${sub.id}' : '套餐';
  }

  static Future<Map<String, String>> _loadPlanMap() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(_kPlanMap) ?? '';
      if (raw.isEmpty) {
        return <String, String>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (e) {
      commonPrint.debug('load plan map failed: $e');
    }
    return <String, String>{};
  }

  static Future<void> _savePlanMap(Map<String, String> map) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_kPlanMap, jsonEncode(map));
    } catch (e) {
      commonPrint.debug('save plan map failed: $e');
    }
  }

  /// 账号下所有仍然可用的套餐（未过期且链接非空），primary 优先、到期时间靠后优先。
  static List<AppSubscription> activeCandidates() {
    final data = AppAuth.instance.account;
    if (data == null) {
      return const [];
    }
    final result = <AppSubscription>[];
    final seen = <String>{};
    void push(AppSubscription? item) {
      if (item == null) {
        return;
      }
      final url = item.subUrl.trim();
      if (url.isEmpty || item.expired || !seen.add(url)) {
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
        // 套餐 id 升序即购买先后顺序，保证先买的套餐优先导入与激活。
        final idCompare = _orderOf(a).compareTo(_orderOf(b));
        if (idCompare != 0) {
          return idCompare;
        }
        return b.daysLeft.compareTo(a.daysLeft);
      });
    for (final item in rest) {
      push(item);
    }
    return result;
  }

  static int _orderOf(AppSubscription sub) => sub.id > 0 ? sub.id : 1 << 30;

  /// 未过期但还没有订阅链接的套餐数量（刚开通、后台尚未生成链接）。
  static int _missingLinkCount() {
    final data = AppAuth.instance.account;
    if (data == null) {
      return 0;
    }
    var count = 0;
    void check(AppSubscription? item) {
      if (item == null) {
        return;
      }
      if (!item.expired && item.subUrl.trim().isEmpty) {
        count++;
      }
    }

    check(data.primary);
    for (final item in data.subscriptions) {
      check(item);
    }
    return count;
  }

  /// 把账号下所有有效套餐分别导入为独立配置（一个套餐一个配置）。
  ///
  /// - 已导入过的套餐按「套餐 ID → 配置 ID」映射复用，续费后订阅链接变化时
  ///   会删除旧配置并按新链接重建，避免出现同名重复配置；
  /// - 用户当前正在使用的套餐配置不会被自动切换，只有当前没有可用配置时
  ///   才会激活第一个套餐，保证「用户自由选择用哪个配置」不被启动流程覆盖；
  /// - 账号里已不存在（退订/删除）的套餐会自动清理其本地配置。
  /// 导入串行队列：登录同步、首页刷新、购买回跳可能在同一时刻触发导入，
  /// 并发下载与并发切换配置会让内核反复重启、界面长时间无响应（表现为卡死），
  /// 因此这里把所有导入请求排队串行执行。
  static Future<void> _chain = Future<void>.value();

  static Future<AppImportResult> importAll({bool activate = true}) {
    final completer = Completer<AppImportResult>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await _importAllOnce(activate: activate));
      } catch (e, stack) {
        commonPrint.warn('AppSubscriptionImporter.importAll crashed: $e\n$stack');
        completer.complete(AppImportResult.failed(_describe(e)));
      }
    });
    return completer.future;
  }

  /// 把账号下所有有效套餐分别导入为独立配置（一个套餐一个配置）。
  ///
  /// - 已导入过的套餐按「套餐 ID → 配置 ID」映射复用，续费后订阅链接变化时
  ///   会删除旧配置并按新链接重建，避免出现同名重复配置；
  /// - 导入阶段只写配置列表、不切换当前配置，全部导入完成后最多激活一次，
  ///   避免每导入一个套餐就重启一次内核导致界面卡死；
  /// - 当前还没有可用配置时优先用直连下载，不依赖尚未启动的内核代理；
  /// - 用户当前正在使用的套餐配置不会被自动切换，只有当前没有可用配置时
  ///   才会激活第一个套餐，保证「用户自由选择用哪个配置」不被启动流程覆盖；
  /// - 账号里已不存在（退订/删除）的套餐会自动清理其本地配置。
  static Future<AppImportResult> _importAllOnce({bool activate = true}) async {
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
    var candidates = activeCandidates();
    // 首次安装（本机还没有任何配置）或账号数据不完整时，先刷新一次账号数据：
    // 一次开通多个套餐时，本地快照可能只有部分套餐（甚至缺第一个购买的套餐），
    // 必须重新拉取完整套餐列表再导入，避免漏导入。
    final firstRun = globalState.config.profiles.isEmpty;
    if (firstRun || candidates.isEmpty || _missingLinkCount() > 0) {
      try {
        await AppAuth.instance.refresh();
      } catch (_) {
        // 刷新失败继续用本地数据判断。
      }
      if (!AppAuth.instance.loggedIn) {
        return const AppImportResult.empty();
      }
      candidates = activeCandidates();
    }
    if (candidates.isEmpty) {
      return const AppImportResult.empty();
    }

    final planMap = await _loadPlanMap();
    final errors = <String>[];
    var importedCount = 0;

    // 用户当前正在使用的配置：本次导入保持不切换，避免覆盖手动选择。
    // 只有当前没有任何可用配置时，才激活第一个（最早购买的）套餐线路。
    final currentId = globalState.config.currentProfileId;
    final keepCurrent =
        currentId != null &&
        globalState.config.profiles.any((item) => item.id == currentId);
    final deferActivate = activate && !keepCurrent;
    Profile? activateTarget;

    // 没有可用配置时内核不会启动，此时只能直连下载；已有配置时优先走
    // 内核代理下载，失败再退化为直连。
    final hasCoreProfile =
        currentId != null &&
        globalState.config.profiles.any((item) => item.id == currentId);
    // 每种下载方式最多尝试一次（校验失败再退化为不校验），避免单个套餐
    // 反复超时把首次导入拖成几十秒。
    final attempts = hasCoreProfile
        ? const <(String, bool)>[('normal', true), ('direct', true), ('direct', false)]
        : const <(String, bool)>[('direct', true), ('direct', false)];

    Profile? findByUrl(String url) {
      for (final item in globalState.config.profiles) {
        if (item.url.trim() == url) {
          return item;
        }
      }
      return null;
    }

    /// 导入阶段只写配置列表，不切换当前配置（避免反复重启内核）。
    Future<void> keepProfile(Profile profile) async {
      globalState.appController.setProfile(profile);
      await AppSubscriptionGuard.instance.recordOwner(profile.id, owner);
    }

    for (final sub in candidates) {
      if (!AppAuth.instance.loggedIn) {
        return const AppImportResult.empty();
      }
      final url = sub.subUrl.trim();
      final key = _planKeyOf(sub);
      final label = _planLabelOf(sub);
      final mappedId = planMap[key];
      Profile? existing = findByUrl(url);
      if (existing == null && mappedId != null) {
        for (final item in globalState.config.profiles) {
          if (item.id == mappedId) {
            existing = item;
            break;
          }
        }
        if (existing != null && existing.url.trim() != url) {
          // 续费后订阅链接发生变化：删除旧配置，按新链接重建同套餐配置。
          try {
            await globalState.appController.deleteProfile(existing.id);
          } catch (e) {
            commonPrint.warn('replace stale plan profile failed: $e');
          }
          existing = null;
        }
      }
      if (existing != null) {
        try {
          await keepProfile(existing);
          planMap[key] = existing.id;
          activateTarget ??= deferActivate ? existing : null;
          importedCount++;
          continue;
        } catch (e) {
          errors.add(_describe(e));
          continue;
        }
      }
      var done = false;
      for (final (mode, validate) in attempts) {
        if (done) {
          break;
        }
        try {
          final profile = Profile.normal(url: url, label: label);
          final imported = mode == 'direct'
              ? await profile.saveFile(
                  await _downloadDirect(url),
                  validate: validate,
                )
              : await profile.update(validate: validate);
          await keepProfile(imported);
          final added = globalState.config.profiles.any(
            (item) => item.id == imported.id || item.url.trim() == url,
          );
          if (!added) {
            throw StateError('配置保存失败');
          }
          planMap[key] = imported.id;
          activateTarget ??= deferActivate ? imported : null;
          importedCount++;
          done = true;
        } catch (e) {
          errors.add(_describe(e));
          if (!AppAuth.instance.loggedIn) {
            return const AppImportResult.empty();
          }
        }
      }
    }

    // 清理账号里已不存在的套餐配置（退订 / 套餐被删除）。
    final validKeys = candidates.map(_planKeyOf).toSet();
    for (final entry in Map<String, String>.from(planMap).entries) {
      if (validKeys.contains(entry.key)) {
        continue;
      }
      planMap.remove(entry.key);
      final staleId = entry.value;
      if (!globalState.config.profiles.any((item) => item.id == staleId)) {
        continue;
      }
      try {
        await globalState.appController.deleteProfile(staleId);
      } catch (e) {
        commonPrint.warn('remove stale plan profile failed: $e');
      }
    }
    await _savePlanMap(planMap);

    // 全部导入完成后统一激活一次（只触发一次内核加载）。
    final target = activateTarget;
    if (target != null) {
      try {
        await globalState.appController.addProfile(target, activate: true);
        await AppSubscriptionGuard.instance.recordOwner(target.id, owner);
      } catch (e) {
        commonPrint.warn('activate plan profile failed: $e');
      }
    }

    if (importedCount > 0) {
      return const AppImportResult.success();
    }
    final message = errors.isEmpty ? '订阅导入失败（未知原因）' : errors.first;
    commonPrint.warn('AppSubscriptionImporter.importAll failed: $message');
    return AppImportResult.failed(message);
  }
}
