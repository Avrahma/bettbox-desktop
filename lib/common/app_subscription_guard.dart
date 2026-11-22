import 'dart:convert';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';

/// 账户隔离：确保本地配置中只保留当前登录账户的套餐订阅。
///
/// 记录 App 自动导入的配置归属（配置 ID -> 账户邮箱），
/// 并在登录、切换账户、退出登录时清除不属于当前账户的订阅配置，
/// 避免未购买套餐的账户直接使用其他账户已导入的订阅。
class AppSubscriptionGuard {
  AppSubscriptionGuard._();

  static final AppSubscriptionGuard instance = AppSubscriptionGuard._();

  static const String _kOwners = 'app_managed_profile_owners';

  Future<void> _queue = Future<void>.value();

  /// 串行执行，避免登出清理与登录清理交错。
  Future<void> _serialize(Future<void> Function() action) {
    final task = _queue.then((_) => action());
    _queue = task.catchError((Object _) {});
    return task;
  }

  /// 当前登录账户的归属标识，未登录返回 null。
  String? _currentOwner() {
    if (!AppAuth.instance.loggedIn) {
      return null;
    }
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

  Future<Map<String, String>> _loadOwners() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      final raw = prefs?.getString(_kOwners);
      if (raw == null || raw.isEmpty) {
        return {};
      }
      final decoded = json.decode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value.toString(),
        };
      }
    } catch (e) {
      commonPrint.debug('AppSubscriptionGuard load failed: $e');
    }
    return {};
  }

  Future<void> _saveOwners(Map<String, String> owners) async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_kOwners, json.encode(owners));
    } catch (e) {
      commonPrint.debug('AppSubscriptionGuard save failed: $e');
    }
  }

  /// 标记某个配置由指定账户的套餐订阅导入。
  Future<void> recordOwner(String profileId, String email) {
    return _serialize(() async {
      final owners = await _loadOwners();
      owners[profileId] = email;
      await _saveOwners(owners);
    });
  }

  /// 是否为本站（订阅门户）下发的订阅链接。
  bool _isSiteSubscription(String url) {
    final value = url.trim();
    if (value.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(value);
    final base = Uri.tryParse(AppAuth.instance.baseUrl);
    if (uri == null || base == null) {
      return false;
    }
    return uri.host.isNotEmpty && uri.host == base.host;
  }

  /// 退出登录时清除本次登出前已存在的订阅配置（含代理节点运行态）。
  ///
  /// [profileIds] 为登出瞬间的配置快照，清理时只处理这批配置，
  /// 不会误删登出后新账户重新导入的配置；不依赖执行时的登录态，
  /// 即使新账户已经登录，也能把上一个账户的配置彻底清掉。
  /// [previousOwner] 为登出前的账户标识，用于写入归属记录兜底。
  Future<void> purgeAllOnLogout({
    Iterable<String>? profileIds,
    String? previousOwner,
  }) {
    final ids = (profileIds ?? globalState.config.profiles.map((e) => e.id))
        .toList();
    return _serialize(() => _purgeAll(ids, previousOwner));
  }

  Future<void> _purgeAll(List<String> ids, String? previousOwner) async {
    // 无论是否有配置需要删除，都必须先真正停掉内核并清空代理节点缓存：
    // 否则配置已被删掉、内核仍在运行，代理页会继续显示上一个账户的线路。
    await _stopCore();
    if (ids.isEmpty) {
      return;
    }
    // 1) 先把这批配置的归属写成登出前的账户，保证即使删除失败或时序被打断，
    //    下一个账户登录执行 enforce 时也会把它们判定为他人配置清掉。
    final owners = await _loadOwners();
    final fallbackOwner = (previousOwner ?? '').trim();
    for (final id in ids) {
      owners[id] = fallbackOwner.isEmpty ? '__logged_out__' : fallbackOwner;
    }
    await _saveOwners(owners);

    // 2) 再次确保内核已停止（防止上一步与启动流程交错）。
    await _stopCore();

    // 3) 逐个删除快照中的配置（不动登出后新导入的配置）。
    final removed = <String>[];
    for (final id in ids) {
      final exists = globalState.config.profiles.any((item) => item.id == id);
      if (!exists) {
        owners.remove(id);
        continue;
      }
      // 若该配置已被新登录账户重新认领，跳过，避免误删。
      final currentOwner = _currentOwner();
      if (currentOwner != null && owners[id] == currentOwner) {
        continue;
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await globalState.appController.deleteProfile(id);
          removed.add(id);
          owners.remove(id);
          break;
        } catch (e) {
          commonPrint.debug('AppSubscriptionGuard purge $id failed: $e');
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    }
    // 兜底：仍有快照中的配置残留时，直接整表清空。
    final leftovers = globalState.config.profiles
        .where((item) => ids.contains(item.id))
        .isNotEmpty;
    if (leftovers) {
      try {
        await globalState.appController.purgeAllProfiles();
        owners.clear();
      } catch (e) {
        commonPrint.debug('AppSubscriptionGuard force purge failed: $e');
      }
    }
    await _saveOwners(owners);
    // 4) 兜底：没有可用配置（或当前配置已失效）时再次停核并清空代理页缓存。
    final currentId = globalState.config.currentProfileId;
    final currentValid =
        currentId != null &&
        globalState.config.profiles.any((item) => item.id == currentId);
    if (!currentValid) {
      await _stopCore();
    }
    if (removed.isNotEmpty) {
      commonPrint.log(
        'AppSubscriptionGuard purged ${removed.length} profile(s) on logout',
      );
    }
  }

  /// 真正停止内核并清空代理节点缓存。
  ///
  /// 不再依赖 `isStart` 判断：退出登录/切换账户时可能存在
  /// `isStart` 已为 false 但 VPN 服务与内核仍在运行的情况。
  Future<void> _stopCore() async {
    try {
      await globalState.appController
          .shutdownAndClearProxies()
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      commonPrint.debug('AppSubscriptionGuard stop core failed: $e');
      // 停止流程异常时也必须清掉代理页缓存。
      try {
        globalState.appController.clearProxyRuntime();
      } catch (_) {}
    }
  }

  /// 清除不属于当前账户的订阅配置。
  ///
  /// [email] 为空表示当前未登录，此时会清除所有由 App 导入的订阅配置。
  /// [allowedUrls] 为当前账户仍有效的订阅链接集合。
  Future<void> enforce({
    required String? email,
    required Set<String> allowedUrls,
    bool dropCurrentOwner = true,
  }) {
    return _serialize(
      () => _enforce(
        email: email,
        allowedUrls: allowedUrls,
        dropCurrentOwner: dropCurrentOwner,
      ),
    );
  }

  Future<void> _enforce({
    required String? email,
    required Set<String> allowedUrls,
    required bool dropCurrentOwner,
  }) async {
    // 任务执行时登录态可能已改变：过期任务直接丢弃，避免误删新账户配置。
    final current = _currentOwner();
    if (current != email) {
      return;
    }
    final owners = await _loadOwners();
    final removedIds = <String>[];
    final profiles = List<Profile>.from(globalState.config.profiles);
    for (final profile in profiles) {
      final owner = owners[profile.id];
      final url = profile.url.trim();
      if (owner != null) {
        final sameOwner = email != null && owner == email;
        if (!sameOwner) {
          // 归属其他账户 → 清除。
          removedIds.add(profile.id);
        } else if (!allowedUrls.contains(url) && dropCurrentOwner) {
          // 同账户但链接已失效/被替换 → 清除。
          removedIds.add(profile.id);
        }
        continue;
      }
      // 旧版本导入的配置没有归属记录：本站订阅链接且不属于当前账户 → 清除。
      if (_isSiteSubscription(url) && !allowedUrls.contains(url)) {
        removedIds.add(profile.id);
      }
    }

    for (final id in removedIds) {
      try {
        await globalState.appController.deleteProfile(id);
        owners.remove(id);
      } catch (e) {
        // 删除失败时保留归属记录，下次登录/登出继续清理。
        commonPrint.debug('AppSubscriptionGuard delete $id failed: $e');
      }
    }

    final alive = globalState.config.profiles.map((item) => item.id).toSet();
    owners.removeWhere((id, _) => !alive.contains(id));
    await _saveOwners(owners);

    if (removedIds.isNotEmpty) {
      // 删掉其他账户的配置后，内核可能仍持有旧配置的线路，必须重建运行态：
      // 有可用配置则按新配置重启，否则直接停核并清空代理页缓存。
      final current = globalState.config.currentProfileId;
      final hasValidCurrent =
          current != null &&
          globalState.config.profiles.any((item) => item.id == current);
      if (!hasValidCurrent) {
        await _stopCore();
      } else if (globalState.isStart) {
        try {
          await globalState.appController.updateStatus(true);
        } catch (e) {
          commonPrint.debug('AppSubscriptionGuard restart core failed: $e');
        }
      }
    }
    if (removedIds.isNotEmpty) {
      commonPrint.log('AppSubscriptionGuard removed ${removedIds.length} profile(s)');
    }
  }
}
