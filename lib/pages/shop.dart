import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/pages/recharge.dart';
import 'package:material_ui/material_ui.dart';

/// 套餐中心：App 内直接查看套餐、用余额购买并自动开通，不跳转浏览器。
///
/// 支付方式仅有余额支付：余额不足时引导到充值页粘贴支付宝口令红包，
/// 管理员确认到账后余额更新，回来即可下单开通。
class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  AppShopData? _data;
  String? _error;
  bool _loading = true;
  int? _buyingPlanId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final data = await AppAuth.instance.fetchShop();
      if (!mounted) {
        return;
      }
      setState(() {
        _data = data;
        _loading = false;
      });
    } on AppApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openRecharge() async {
    await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const RechargePage()));
    if (!mounted) {
      return;
    }
    await AppAuth.instance.refresh();
    await _load();
  }

  Future<void> _buy(AppPlan plan) async {
    final data = _data;
    if (data == null || _buyingPlanId != null) {
      return;
    }
    final balance = data.balance;
    final shortfall = double.parse((plan.price - balance).toStringAsFixed(2));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: Text('购买 ${plan.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(theme, '套餐', plan.name),
              _kv(theme, '周期', plan.periodText),
              _kv(theme, '应付金额', '¥${plan.price.toStringAsFixed(2)}'),
              _kv(theme, '当前余额', '¥${balance.toStringAsFixed(2)}'),
              const SizedBox(height: 8),
              Text(
                shortfall > 0
                    ? '余额不足，还差 ¥${shortfall.toStringAsFixed(2)}，需要先充值'
                    : '支付后余额 ¥${(balance - plan.price).toStringAsFixed(2)}，'
                          '确认后立即开通订阅',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: shortfall > 0
                      ? colorScheme.error
                      : colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '支付方式：余额支付',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(shortfall > 0 ? '去充值' : '余额支付'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    if (shortfall > 0) {
      await _openRecharge();
      return;
    }
    setState(() => _buyingPlanId = plan.id);
    try {
      final result = await AppAuth.instance.purchaseWithBalance(plan.id);
      await AppAuth.instance.refresh();
      await _load();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('购买成功'),
          content: Text(
            '${result.message}\n\n套餐：${plan.name}\n'
            '到期时间：${result.expiresOn.isEmpty ? '以订阅页为准' : result.expiresOn}\n'
            '当前余额：¥${result.balance.toStringAsFixed(2)}\n\n'
            '订阅已自动下发到配置页，可直接使用。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on AppPurchaseException catch (e) {
      if (!mounted) {
        return;
      }
      _toast(e.message);
      if (e.needRecharge) {
        await _openRecharge();
      }
    } on AppApiException catch (e) {
      if (mounted) {
        _toast(e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _buyingPlanId = null);
      }
    }
  }

  Widget _kv(ThemeData theme, String label, String value) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final data = _data;

    return Scaffold(
      appBar: AppBar(
        title: const Text('套餐中心'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && data == null
            ? _ErrorView(message: _error!, onRetry: () => unawaited(_load()))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    _BalanceBar(
                      balance: data?.balance ?? 0,
                      onRecharge: () => unawaited(_openRecharge()),
                    ),
                    const SizedBox(height: 18),
                    _SectionTitle(title: '选择套餐'),
                    const SizedBox(height: 6),
                    if ((data?.plans ?? const <AppPlan>[]).isEmpty)
                      _EmptyHint(text: '暂无可购买套餐，请联系客服')
                    else
                      for (final plan in data!.plans) ...[
                        _PlanCard(
                          plan: plan,
                          balance: data.balance,
                          busy: _buyingPlanId != null,
                          onBuy: () => unawaited(_buy(plan)),
                        ),
                        const SizedBox(height: 10),
                      ],
                    const SizedBox(height: 18),
                    _SectionTitle(title: '我的订单'),
                    const SizedBox(height: 6),
                    if ((data?.orders ?? const <AppOrder>[]).isEmpty)
                      _EmptyHint(text: '暂无订单，选择上方套餐即可下单')
                    else
                      for (final order in data!.orders) ...[
                        _OrderCard(order: order),
                        const SizedBox(height: 10),
                      ],
                    const SizedBox(height: 4),
                    Text(
                      '说明：全站仅支持余额支付。余额通过支付宝口令红包充值，'
                      '管理员确认到账后余额自动更新，余额充足即可直接购买并自动开通。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _BalanceBar extends StatelessWidget {
  const _BalanceBar({required this.balance, required this.onRecharge});

  final double balance;
  final VoidCallback onRecharge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            color: colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '账户余额',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onPrimaryContainer.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '¥ ${balance.toStringAsFixed(2)}',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonal(
            onPressed: onRecharge,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('充值'),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.balance,
    required this.busy,
    required this.onBuy,
  });

  final AppPlan plan;
  final double balance;
  final bool busy;
  final VoidCallback onBuy;

  String get _priceText => plan.price == plan.price.roundToDouble()
      ? plan.price.toStringAsFixed(0)
      : plan.price.toStringAsFixed(2);

  // 「注意 不接受退款」这类条款用弱化图标，避免和正常权益混在一起。
  bool _isNote(String text) => text.contains('注意') || text.contains('退款');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final enough = balance >= plan.price;
    final tier = plan.tierLabel.trim();
    final hint = plan.monthlyHint;
    final onHeader = colorScheme.onPrimaryContainer;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colorScheme.primaryContainer.withValues(alpha: 0.95),
                  colorScheme.primaryContainer.withValues(alpha: 0.34),
                ],
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            plan.name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: onHeader,
                            ),
                          ),
                          if (tier.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: onHeader.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                tier,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: onHeader,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${plan.periodText}有效期',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: onHeader.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '¥',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: onHeader,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text: _priceText,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: onHeader,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (hint.isNotEmpty)
                      Text(
                        hint,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: onHeader.withValues(alpha: 0.72),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in plan.bullets)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            _isNote(item)
                                ? Icons.info_outline
                                : Icons.check_circle_outline,
                            size: 15,
                            color: _isNote(item)
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            item,
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.45,
                              color: _isNote(item)
                                  ? colorScheme.onSurfaceVariant
                                  : colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        enough
                            ? '余额支付 · 购买后立即开通'
                            : '余额不足 ¥${(plan.price - balance).toStringAsFixed(2)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: enough
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.error,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: busy ? null : onBuy,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('购买'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final AppOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = order.approved ? Colors.green : colorScheme.primary;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    order.planName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '¥${order.amount.toStringAsFixed(2)} · ${order.createdAt}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                order.statusLabel.isEmpty ? order.status : order.statusLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: statusColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
