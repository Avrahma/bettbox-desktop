import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// 套餐中心：App 内选择套餐、粘贴支付宝口令、查看订单与开通状态。
///
/// 流程：选套餐 → 支付宝按金额转账/发红包 → 把生成的口令粘贴提交 →
/// 服务端立即按「新订单」提醒管理员 → 管理员在后台确认收款并分配订阅。
class ShopPage extends StatefulWidget {
  const ShopPage({super.key});

  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  AppShopData? _data;
  String? _error;
  bool _loading = true;

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

  Future<void> _openPaySheet({AppPlan? plan, AppOrder? order}) async {
    final data = _data;
    if (data == null) {
      return;
    }
    if (plan == null && order == null) {
      return;
    }
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: _PaySheet(
          planName: order?.planName ?? plan!.name,
          amount: order?.amount ?? plan!.price,
          payGuide: data.payGuide,
          codeLimit: data.codeLimit,
          initialCode: order?.alipayCode ?? '',
          orderId: order?.id,
          planId: plan?.id,
          onOrderCreated: (message) {
            Navigator.of(sheetContext).pop(true);
            if (!mounted) {
              return;
            }
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          },
        ),
      ),
    );
    if (changed == true) {
      await _load();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已提交，等待管理员确认收款')));
    }
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
                    _BalanceBar(balance: data?.balance ?? 0),
                    const SizedBox(height: 18),
                    _SectionTitle(
                      title: '选择套餐',
                      trailing: TextButton(
                        onPressed: () => unawaited(
                          globalState.openUrl(
                            AppAuth.instance.purchaseUrl ?? '',
                          ),
                        ),
                        child: const Text('网页版'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if ((data?.plans ?? const <AppPlan>[]).isEmpty)
                      _EmptyHint(text: '暂无可购买套餐，请联系客服')
                    else
                      for (final plan in data!.plans) ...[
                        _PlanCard(
                          plan: plan,
                          onBuy: () => unawaited(_openPaySheet(plan: plan)),
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
                        _OrderCard(
                          order: order,
                          onClaim: order.waitingCode
                              ? () => unawaited(_openPaySheet(order: order))
                              : null,
                        ),
                        const SizedBox(height: 10),
                      ],
                    const SizedBox(height: 4),
                    Text(
                      '说明：口令提交后订单进入待确认，管理员领取红包并确认收款后，'
                      '系统会自动为你开通或续期套餐，无需再次操作。',
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
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

class _BalanceBar extends StatelessWidget {
  const _BalanceBar({required this.balance});

  final double balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.account_balance_wallet_outlined, color: colorScheme.primary),
          const SizedBox(width: 10),
          Text('账户余额', style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(
            '¥${_money(balance)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.onBuy});

  final AppPlan plan;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surfaceContainerLowest,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '¥${_money(plan.price)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '服务期限：${plan.periodText}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            plan.summary,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: FilledButton(
              onPressed: onBuy,
              child: const Text('支付宝口令购买'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, this.onClaim});

  final AppOrder order;
  final VoidCallback? onClaim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (label, color) = _statusStyle(colorScheme);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#${order.id}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  order.planName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '¥${_money(order.amount)} · ${order.createdAt}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (order.alipayCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '口令：${order.alipayCode}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '复制口令',
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: order.alipayCode),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('口令已复制')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                ),
              ],
            ),
          ],
          if (onClaim != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onClaim,
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('填写支付宝口令'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  (String, Color) _statusStyle(ColorScheme colorScheme) {
    if (order.approved) {
      return ('已开通', const Color(0xFF2E7D32));
    }
    if (order.status == 'rejected') {
      return ('已拒绝', colorScheme.error);
    }
    if (order.waitingReview) {
      return ('待确认收款', const Color(0xFFE65100));
    }
    return ('待提交口令', colorScheme.primary);
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
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
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, color: theme.colorScheme.error),
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

/// 支付面板：展示应付金额与操作步骤，收集支付宝口令。
class _PaySheet extends StatefulWidget {
  const _PaySheet({
    required this.planName,
    required this.amount,
    required this.payGuide,
    required this.codeLimit,
    required this.initialCode,
    required this.onOrderCreated,
    this.orderId,
    this.planId,
  });

  final String planName;
  final double amount;
  final String payGuide;
  final int codeLimit;
  final String initialCode;
  final int? orderId;
  final int? planId;
  final ValueChanged<String> onOrderCreated;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialCode,
  );
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit({required bool withCode}) async {
    if (_submitting) {
      return;
    }
    final code = _controller.text.trim();
    if (withCode && code.length < 4) {
      setState(() => _error = '请粘贴完整的支付宝口令');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final auth = AppAuth.instance;
      if (widget.orderId != null) {
        await auth.claimOrder(orderId: widget.orderId!, alipayCode: code);
      } else {
        await auth.submitOrder(
          planId: widget.planId ?? 0,
          alipayCode: withCode ? code : '',
        );
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on AppApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.planName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Text(
            '¥${_money(widget.amount)}',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: colorScheme.primary,
            ),
          ),
          const SizedBox(height: 14),
          _Step(index: 1, text: '打开支付宝，按上方金额转账或发红包给站长'),
          _Step(index: 2, text: '支付完成后，复制支付宝生成的「口令」'),
          _Step(index: 3, text: '回到这里粘贴口令并提交，管理员确认后自动开通'),
          if (widget.payGuide.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.6,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.payGuide.trim(),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            enabled: !_submitting,
            maxLength: widget.codeLimit > 0 ? widget.codeLimit : 180,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: '支付宝口令 / 红包口令',
              hintText: '把支付宝里生成的口令粘贴到这里',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              ),
            ),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _submitting
                  ? null
                  : () => unawaited(_submit(withCode: true)),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('我已付款，提交口令'),
            ),
          ),
          if (widget.orderId == null)
            TextButton(
              onPressed: _submitting
                  ? null
                  : () => unawaited(_submit(withCode: false)),
              child: const Text('先创建订单，稍后再填口令'),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

String _money(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(2);
}
