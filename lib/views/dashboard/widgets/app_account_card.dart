import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/app_notice.dart';
import 'package:bett_box/common/app_subscription_importer.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/expired_subscription_guard.dart';
import 'package:bett_box/pages/notice.dart';
import 'package:bett_box/pages/shop.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 跟随系统字号轻微放大的间距，与全局 `ap` 规则一致，但不依赖 globalState，
/// 便于在无全局状态的渲染测试中复用。
double _ap(BuildContext context, double value) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  return value * (1 + (scale - 1) * 0.5);
}

/// 首页顶部的账号与套餐信息卡片。
///
/// 视觉沿用应用内其它 Dashboard 卡片的写法：CommonCard 圆角 + 图标标题行 +
/// 16 左右内边距的内容区；信息以浅底面板分组，主操作放到底部。
/// 未开通套餐时只展示账号、余额与「购买套餐」入口；
/// 已开通套餐时才展示到期时间、剩余时长、流量与「续费 / 管理」入口。
class AppAccountCard extends ConsumerStatefulWidget {
  const AppAccountCard({super.key});

  @override
  ConsumerState<AppAccountCard> createState() => _AppAccountCardState();
}

class _AppAccountCardState extends ConsumerState<AppAccountCard> {
  bool _refreshing = false;
  bool _importing = false;

  /// 手动把账号当前套餐的订阅导入为配置，并给出明确结果提示。
  Future<void> _reimport() async {
    if (_importing) {
      return;
    }
    setState(() => _importing = true);
    final result = await AppSubscriptionImporter.importAll(activate: true);
    if (!mounted) {
      return;
    }
    setState(() => _importing = false);
    String text;
    if (result.ok) {
      text = '订阅已导入并启用；如需切换套餐，请到首页「配置」模块中选择。';
    } else if (result.noSubscription) {
      text = '当前账号没有可用订阅链接，请先在套餐中心购买或续费。';
    } else {
      text = result.message ?? '订阅导入失败，请稍后重试。';
    }
    unawaited(
      globalState.showMessage(
        title: '订阅导入',
        message: TextSpan(text: text),
        cancelable: false,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_autoShowNotice());
    });
  }

  /// 每次启动 / 每次登录进入首页时自动弹窗展示公告（同一会话只弹一次）。
  Future<void> _autoShowNotice() async {
    await AppNoticeCenter.instance.refresh();
    if (!mounted) {
      return;
    }
    final notice = AppNoticeCenter.instance.notice;
    if (notice == null || !notice.hasNotice) {
      return;
    }
    if (!AppNoticeCenter.instance.beginAutoShow()) {
      return;
    }
    await showAppNoticeDialog(context);
    await AppNoticeCenter.instance.markRead();
  }

  /// 手动点「公告」入口：拉取后弹窗展示，无公告时给出提示。
  Future<void> _openNotice() async {
    await AppNoticeCenter.instance.refresh();
    if (!mounted) {
      return;
    }
    final notice = AppNoticeCenter.instance.notice;
    if (notice == null || !notice.hasNotice) {
      await globalState.showMessage(
        message: const TextSpan(text: '暂无公告'),
        confirmText: '知道了',
      );
      return;
    }
    await showAppNoticeDialog(context);
    await AppNoticeCenter.instance.markRead();
  }

  Future<bool> _ensureRefreshed() async {
    final valid = await AppAuth.instance.refresh();
    if (!valid) {
      await AppAuth.instance.logout();
    }
    return valid;
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    unawaited(_autoShowNotice());
    final valid = await _ensureRefreshed();
    if (!mounted) {
      return;
    }
    setState(() => _refreshing = false);
    if (!valid) {
      return;
    }
    // 刷新到新套餐/续费结果后，自动补做一次订阅导入，避免只有账号信息没有线路。
    unawaited(AppSubscriptionImporter.importAll(activate: true));
    unawaited(
      globalState.showMessage(
        title: '提示',
        message: const TextSpan(text: '账户信息已刷新'),
        cancelable: false,
      ),
    );
  }

  /// 打开套餐中心：App 内查看套餐、用余额购买并自动开通。
  void _openShop() {
    unawaited(
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ShopPage())),
    );
  }

  Future<void> _logout() async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出登录会清除本机已导入的配置（含手动添加的配置），重新登录后按当前账号的套餐自动恢复。'),
        actions: [
          TextButton(
            // 桌面端每个 Tab 内容都套在各自的 Navigator 里，必须显式回到
            // 根 Navigator 才能关闭本对话框，否则只会 pop 掉 Tab 内的页面，
            // 对话框仍停留在屏幕上（表现为“卡在退出登录提示”）。
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
            child: Text(
              '退出',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await AppAuth.instance.logout();
    } catch (e) {
      commonPrint.warn('AppAccountCard logout failed: $e');
      if (!mounted) {
        return;
      }
      unawaited(
        globalState.showMessage(
          title: '提示',
          message: const TextSpan(text: '退出登录失败，请重试'),
          cancelable: false,
        ),
      );
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// 图标标题行，对齐应用内其它卡片的 InfoHeader 写法。
  Widget _buildHeaderRow(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _ap(context, 16),
        _ap(context, 11),
        _ap(context, 8),
        0,
      ),
      child: Row(
        children: [
          AppIcon(Icons.person_outline, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '账户',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(width: _ap(context, 14)),
                _buildNoticeEntry(context),
              ],
            ),
          ),
          IconButton(
            onPressed: _importing ? null : () => unawaited(_reimport()),
            tooltip: '重新导入订阅',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
            icon: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const AppIcon(Icons.cloud_download_outlined, size: 19),
          ),
          const SizedBox(width: 10),
          IconButton(
            onPressed: _refreshing ? null : () => unawaited(_refresh()),
            tooltip: '刷新账户信息',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
            icon: _refreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const AppIcon(Icons.refresh, size: 19),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => unawaited(_logout()),
            style: TextButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.symmetric(horizontal: _ap(context, 6)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
            child: Text(
              '退出',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 公告入口：紧跟「账户」标题，后台发布新公告时右上角显示红点。
  Widget _buildNoticeEntry(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final unread = AppNoticeCenter.instance.hasUnread;
    return InkWell(
      onTap: () => unawaited(_openNotice()),
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _ap(context, 8),
          vertical: _ap(context, 3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                    child: AppIcon(
                      Icons.campaign_outlined,
                      size: 17,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (unread)
                    Positioned(
                      top: 0,
                      right: -1,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: colorScheme.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: _ap(context, 4)),
            Text(
              '公告',
              style: theme.textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单个信息项：上方浅色小标签，下方数值。
  /// 长按「到期时间」打开的到期守护自检面板：看闹钟有没有挂上、看门狗有没有在跑，
  /// 并可直接模拟 60 秒后到期来验证后台到点断开。
  Future<void> _showExpiryGuardPanel(BuildContext context) async {
    final status = await ExpiredSubscriptionGuard.statusText();
    final navigatorContext = globalState.navigatorKey.currentContext;
    if (navigatorContext == null) return;
    final confirmed = await globalState.showMessage(
      title: '到期守护自检',
      message: TextSpan(text: status),
      cancelText: '关闭',
      confirmText: '模拟 60 秒后到期',
    );
    if (confirmed != true) return;
    final ok = await ExpiredSubscriptionGuard.simulateExpiry(seconds: 60);
    if (!ok) {
      await globalState.showMessage(
        title: '自检未启动',
        message: const TextSpan(text: '当前系统不支持模拟到期（仅 Android 端可用）。'),
        confirmText: '知道了',
        cancelable: false,
      );
      return;
    }
    await globalState.showMessage(
      title: '已开始自检',
      message: const TextSpan(
        text: '60 秒后到点：请立刻按 Home 键或锁屏，观察通知栏常驻通知与 VPN 图标是否自动消失。'
            '回到 App 后会提示自检结果。',
      ),
      confirmText: '知道了',
      cancelable: false,
    );
  }

  Widget _kv(
    BuildContext context, {
    required String label,
    required String value,
    Color? valueColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _vLine(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 1,
      height: _ap(context, 24),
      margin: EdgeInsets.symmetric(horizontal: _ap(context, 12)),
      color: colorScheme.outlineVariant.withValues(alpha: 0.45),
    );
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required Color color,
    required String text,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(BuildContext context, String seed) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = seed.isEmpty ? 'A' : seed.substring(0, 1).toUpperCase();
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 信息面板：浅底圆角容器，内部按 2 列排布，列间细分割线。
  Widget _buildInfoPanel(
    BuildContext context, {
    required AppAccountData account,
    required AppSubscription? sub,
    required Color statusColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final balanceText = '¥${account.account.balance.toStringAsFixed(2)}';
    final traffic = sub?.traffic;

    final children = <Widget>[];
    if (sub == null) {
      children.add(
        Row(
          children: [
            Expanded(
              child: _kv(context, label: '账户余额', value: balanceText),
            ),
            _vLine(context),
            Expanded(
              child: _kv(
                context,
                label: '账户状态',
                value: account.account.isActive ? '正常' : '已停用',
              ),
            ),
          ],
        ),
      );
    } else {
      children.add(
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => _showExpiryGuardPanel(context),
                child: _kv(
                  context,
                  label: '到期时间',
                  value: sub.expiresOn.isEmpty ? '—' : sub.expiresOn,
                ),
              ),
            ),
            _vLine(context),
            Expanded(
              child: _kv(
                context,
                label: '剩余时长',
                value: sub.expired
                    ? '已到期'
                    : sub.daysLeft < 0
                    ? '长期'
                    : '${sub.daysLeft} 天',
                valueColor: sub.expired ? colorScheme.error : null,
              ),
            ),
          ],
        ),
      );
      children.add(SizedBox(height: _ap(context, 12)));
      children.add(
        Row(
          children: [
            Expanded(
              child: _kv(
                context,
                label: traffic == null ? '账户余额' : '已用流量',
                value: traffic == null ? balanceText : traffic.usedText,
              ),
            ),
            _vLine(context),
            Expanded(
              child: _kv(
                context,
                label: traffic == null ? '账户状态' : '可用流量',
                value: traffic == null
                    ? (account.account.isActive ? '正常' : '已停用')
                    : (traffic.total <= 0
                          ? '不限'
                          : appFormatBytes(traffic.total - traffic.used)),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: _ap(context, 14),
        vertical: _ap(context, 12),
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  /// 流量进度条：渐变填充 + 底部百分比与总额说明。
  Widget _buildTrafficBar(
    BuildContext context, {
    required AppSubscription sub,
    required Color statusColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final traffic = sub.traffic;
    if (traffic == null || traffic.total <= 0) {
      return const SizedBox.shrink();
    }
    final color = traffic.ratio > 0.9 ? colorScheme.error : statusColor;
    final percent = '${(traffic.ratio * 100).round()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: _ap(context, 12)),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 7,
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            child: FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: traffic.ratio.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color, color.withValues(alpha: 0.55)],
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: _ap(context, 6)),
        Row(
          children: [
            Expanded(
              child: Text(
                '已用 $percent',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '共 ${traffic.totalText}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required AppAccountData account,
    required AppSubscription? sub,
    required Color statusColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = account.account.name;
    final email = account.account.email;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _ap(context, 16),
        _ap(context, 8),
        _ap(context, 16),
        _ap(context, 16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _buildAvatar(context, email.isNotEmpty ? email : name),
              SizedBox(width: _ap(context, 12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      email.isNotEmpty ? email : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub == null
                          ? '未开通套餐'
                          : (sub.planName.isEmpty ? '订阅' : sub.planName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (sub != null) ...[
                const SizedBox(width: 10),
                _buildStatusChip(
                  context,
                  color: statusColor,
                  text: sub.statusText,
                ),
              ],
            ],
          ),
          SizedBox(height: _ap(context, 14)),
          _buildInfoPanel(
            context,
            account: account,
            sub: sub,
            statusColor: statusColor,
          ),
          if (sub != null)
            _buildTrafficBar(context, sub: sub, statusColor: statusColor),
          if (sub == null) ...[
            SizedBox(height: _ap(context, 12)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: AppIcon(
                    Icons.info_outline,
                    size: 14,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '开通套餐后自动导入订阅，可在此查看到期时间与流量',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: _ap(context, 16)),
          Row(
            children: [
              FilledButton(
                onPressed: _openShop,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  textStyle: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                child: Text(sub == null ? '购买套餐' : '续费 / 管理', maxLines: 1),
              ),
              const SizedBox(width: 8),
              const Spacer(),
              Flexible(
                child: Text(
                  sub == null ? '未开通' : '订阅有效',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 找出当前激活配置对应的套餐。
  ///
  /// 配置链接与套餐订阅链接一致即视为同一套餐；当前配置不是账号套餐
  /// （例如手动添加的配置）时退回账号主套餐，保证卡片始终有内容可显示。
  AppSubscription? _resolveActiveSub(AppAccountData account) {
    final currentId = globalState.config.currentProfileId;
    if (currentId != null) {
      for (final profile in globalState.config.profiles) {
        if (profile.id != currentId) {
          continue;
        }
        final url = profile.url.trim();
        if (url.isEmpty) {
          break;
        }
        for (final sub in account.subscriptions) {
          if (sub.subUrl.trim() == url) {
            return sub;
          }
        }
        break;
      }
    }
    return account.primary;
  }

  @override
  Widget build(BuildContext context) {
    // 监听当前选中的配置，切换套餐配置后卡片立即刷新。
    ref.watch(currentProfileIdProvider);
    ref.listen<String?>(currentProfileIdProvider, (previous, next) {
      if (previous == null || next == null || previous == next) {
        return;
      }
      // 切换到另一个套餐的配置后，拉一次最新账号数据，
      // 让到期时间、剩余时长与流量都与所选套餐对齐。
      unawaited(AppAuth.instance.refresh());
    });
    return AnimatedBuilder(
      animation: Listenable.merge([AppAuth.instance, AppNoticeCenter.instance]),
      builder: (context, _) {
        final account = AppAuth.instance.account;
        if (account == null) {
          return const SizedBox.shrink();
        }
        final colorScheme = Theme.of(context).colorScheme;
        // 展示「当前选中配置」对应的套餐：用户在「配置」中切换套餐后，
        // 卡片上的套餐名称、到期时间、剩余时长与流量随之切换。
        final sub = _resolveActiveSub(account);

        Color statusColor;
        if (sub == null || sub.expired) {
          statusColor = colorScheme.error;
        } else if (sub.daysLeft >= 0 && sub.daysLeft <= 3) {
          statusColor = Colors.orange;
        } else {
          statusColor = colorScheme.primary;
        }

        return CommonCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeaderRow(context),
              _buildBody(
                context,
                account: account,
                sub: sub,
                statusColor: statusColor,
              ),
            ],
          ),
        );
      },
    );
  }
}
