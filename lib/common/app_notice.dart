import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/common.dart';
import 'package:material_ui/material_ui.dart';

/// 客户端公告状态：拉取服务端公告，并维护「未读红点」。
///
/// 判断规则：服务端 published_at 与本地已读时间不同即视为有新公告。
/// 进入公告页后调用 [markRead] 记录已读时间，红点消失。
class AppNoticeCenter extends ChangeNotifier {
  AppNoticeCenter._();

  static final AppNoticeCenter instance = AppNoticeCenter._();

  static const String _kReadAt = 'app_notice_read_at';

  AppNotice? _notice;
  String _readAt = '';
  bool _loading = false;
  bool _restored = false;
  Future<void>? _inflight;

  AppNotice? get notice => _notice;

  bool get loading => _loading;

  /// 是否有未读公告（后台发布了新内容即显示红点）。
  bool get hasUnread {
    final item = _notice;
    if (item == null || !item.hasNotice) {
      return false;
    }
    final published = item.publishedAt.trim();
    if (published.isEmpty) {
      return false;
    }
    return published != _readAt;
  }

  Future<void> _restore() async {
    if (_restored) {
      return;
    }
    _restored = true;
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      _readAt = prefs?.getString(_kReadAt) ?? '';
    } catch (e) {
      commonPrint.debug('AppNoticeCenter restore failed: $e');
    }
  }

  /// 拉取公告。失败时静默保留旧数据，不打断首页。
  ///
  /// 并发调用共享同一次请求，调用方都能等到最新结果（用于自动弹窗判断）。
  Future<void> refresh() async {
    final running = _inflight;
    if (running != null) {
      await running;
      return;
    }
    final future = _fetch();
    _inflight = future;
    try {
      await future;
    } finally {
      _inflight = null;
    }
  }

  Future<void> _fetch() async {
    _loading = true;
    try {
      await _restore();
      _notice = await AppAuth.instance.fetchNotice();
      notifyListeners();
    } catch (e) {
      commonPrint.debug('AppNoticeCenter refresh failed: $e');
    } finally {
      _loading = false;
    }
  }

  /// 标记当前公告为已读。
  Future<void> markRead() async {
    final item = _notice;
    if (item == null || item.publishedAt.trim().isEmpty) {
      return;
    }
    if (_readAt == item.publishedAt) {
      return;
    }
    _readAt = item.publishedAt;
    notifyListeners();
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_kReadAt, _readAt);
    } catch (e) {
      commonPrint.debug('AppNoticeCenter markRead failed: $e');
    }
  }
}
