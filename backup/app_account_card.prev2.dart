import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

/// 首页顶部的账号与套餐信息卡片。
class AppAccountCard extends StatefulWidget {
  const AppAccountCard({super.key});

  @override
  State<AppAccountCard> createState() => _AppAccountCardState();
}

class _AppAccountCardState extends State<AppAccountCard> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    setState(() => _refreshing = true);
    final valid = await AppAuth.instance.refresh();
    if (!mounted) {
      return;
    }
    setState(() => _refreshing = false);
    if (!valid) {
      await AppAuth.instance.logout();
      return;
    }
    if (mounted) {
      unawaited(
        globalState.showMessage(
          title: '提示',
          message: const TextSpan(text: '账户信息已刷新'),
          cancelable: false,
        ),
      );
    }
  }

  Future<void> _openRenewal() async {
    var url = AppAuth.instance.renewalUrl;
    if (url == null) {
      final valid = await AppAuth.instance.refresh();
      if (!valid) {
        await AppAuth.instance.logout();
        return;
      }
      url = AppAuth.instance.renewalUrl;
    }
    if (url == null) {
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

  /// 单个信息块：浅底圆角，内容宽度由外层 Expanded 约束，不会横向溢出。
  Widget _stat(
    BuildContext context, {
    required String label,
    required String value,
    Color? valueColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
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
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
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
        final auth = AppAuth.instance;
        final account = auth.account;
        if (account == null) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final sub = account.primary;
        final traffic = sub?.traffic;
        final name = account.account.name;
        final avatarText = name.isEmpty
            ? 'A'
            : name.substring(0, 1).toUpperCase();

        Color statusColor;
        if (sub == null || sub.expired) {
          statusColor = colorScheme.error;
        } else if (sub.daysLeft >= 0 && sub.daysLeft <= 3) {
          statusColor = Colors.orange;
        } else {
          statusColor = colorScheme.primary;
        }

        final daysText = sub == null
            ? '—'
            : sub.expired
            ? '已到期'
            : sub.daysLeft < 0
            ? '长期'
            : '${sub.daysLeft} 天';

        final expireText = (sub == null || sub.expiresOn.isEmpty)
            ? '—'
            : sub.expiresOn;

        final trafficText = traffic == null
            ? '—'
            : '${traffic.usedText} / ${traffic.totalText}';

        return CommonCard(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      avatarText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub == null
                              ? '暂无有效套餐'
                              : (sub.planName.isEmpty ? '订阅' : sub.planName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          sub.statusText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _stat(
                      context,
                      label: '到期时间',
                      value: expireText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _stat(
                      context,
                      label: '剩余时长',
                      value: daysText,
                      valueColor: (sub == null || sub.expired)
                          ? colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _stat(
                      context,
                      label: '账户余额',
                      value: '¥${account.account.balance.toStringAsFixed(2)}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _stat(
                      context,
                      label: traffic == null ? '账户状态' : '已用流量',
                      value: traffic == null
                          ? (account.account.isActive ? '正常' : '已停用')
                          : trafficText,
                    ),
                  ),
                ],
              ),
              if (traffic != null && traffic.total > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: traffic.ratio,
                    minHeight: 5,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      traffic.ratio > 0.9 ? colorScheme.error : statusColor,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => unawaited(_openRenewal()),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text(
                        '续费 / 管理',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: _refreshing ? null : () => unawaited(_refresh()),
                    tooltip: '刷新账号信息',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: _refreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const AppIcon(Icons.refresh, size: 20),
                  ),
                  IconButton(
                    onPressed: () => unawaited(_logout()),
                    tooltip: '退出登录',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const AppIcon(Icons.logout, size: 20),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
