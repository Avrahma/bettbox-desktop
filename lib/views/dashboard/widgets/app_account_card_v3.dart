import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
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
class AppAccountCard extends StatefulWidget {
  const AppAccountCard({super.key});

  @override
  State<AppAccountCard> createState() => _AppAccountCardState();
}

class _AppAccountCardState extends State<AppAccountCard> {
  bool _refreshing = false;

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
    final valid = await _ensureRefreshed();
    if (!mounted) {
      return;
    }
    setState(() => _refreshing = false);
    if (!valid) {
      return;
    }
    unawaited(
      globalState.showMessage(
        title: '提示',
        message: const TextSpan(text: '账户信息已刷新'),
        cancelable: false,
      ),
    );
  }

  /// 打开站点的指定页面（购买 / 续费），已登录时按 ticket 免密进入。
  Future<void> _openSite(String Function(AppAuth auth) urlOf) async {
    var url = urlOf(AppAuth.instance);
    if (url.isEmpty) {
      final valid = await _ensureRefreshed();
      if (!valid) {
        return;
      }
      url = urlOf(AppAuth.instance);
    }
    if (url.isEmpty) {
      return;
    }
    unawaited(globalState.openUrl(url));
  }

  Future<void> _logout() async {
    final confirmed = await globalState.showCommonDialog<bool>(
      child: AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入账号密码，已导入的配置不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await AppAuth.instance.logout();
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
          AppIcon(
            Icons.person_outline,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '账户',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
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
          IconButton(
            onPressed: () => unawaited(_logout()),
            tooltip: '退出登录',
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
            icon: const AppIcon(Icons.logout, size: 19),
          ),
        ],
      ),
    );
  }

  /// 单个信息项：上方浅色小标签，下方数值。
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

  Widget _buildAvatar(BuildContext context, String name) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final text = name.isEmpty ? 'A' : name.substring(0, 1).toUpperCase();
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
              child: _kv(
                context,
                label: '到期时间',
                value: sub.expiresOn.isEmpty ? '—' : sub.expiresOn,
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
                    colors: [
                      color,
                      color.withValues(alpha: 0.55),
                    ],
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
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
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
              _buildAvatar(context, name),
              SizedBox(width: _ap(context, 12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
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
                    if (email.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ],
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
          if (sub != null) _buildTrafficBar(context, sub: sub, statusColor: statusColor),
          if (sub == null) ...[
            SizedBox(height: _ap(context, 10)),
            Text(
              '开通套餐后自动导入订阅，可在此查看到期时间与流量',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: labelStyle?.copyWith(height: 1.45),
            ),
          ],
          SizedBox(height: _ap(context, 16)),
          Row(
            children: [
              FilledButton(
                onPressed: () => unawaited(
                  _openSite(
                    (auth) => sub == null
                        ? (auth.purchaseUrl ?? '')
                        : (auth.renewalUrl ?? ''),
                  ),
                ),
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
                child: Text(
                  sub == null ? '购买套餐' : '续费 / 管理',
                  maxLines: 1,
                ),
              ),
              const Spacer(),
              Text(
                sub == null ? '未开通' : '订阅有效',
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppAuth.instance,
      builder: (context, _) {
        final account = AppAuth.instance.account;
        if (account == null) {
          return const SizedBox.shrink();
        }
        final colorScheme = Theme.of(context).colorScheme;
        final sub = account.primary;

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
