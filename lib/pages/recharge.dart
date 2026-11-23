import 'dart:async';

import 'package:bett_box/common/app_api.dart';
import 'package:material_ui/material_ui.dart';

/// 余额充值：粘贴支付宝口令红包密码提交，管理员核对后加到账户余额。
///
/// 流程：支付宝发口令红包 → 把口令粘贴提交 → 服务端生成待确认充值单并
/// 邮件提醒管理员 → 管理员领取红包后在后台调整余额。
class RechargePage extends StatefulWidget {
  const RechargePage({super.key});

  @override
  State<RechargePage> createState() => _RechargePageState();
}

class _RechargePageState extends State<RechargePage> {
  final TextEditingController _codeController = TextEditingController();
  AppWallet? _wallet;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = _wallet == null;
      _error = null;
    });
    try {
      final wallet = await AppAuth.instance.fetchWallet();
      if (!mounted) {
        return;
      }
      setState(() {
        _wallet = wallet;
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

  Future<void> _submit() async {
    if (_submitting) {
      return;
    }
    final code = _codeController.text.trim();
    if (code.length < 4) {
      _toast('请填写完整的支付宝口令红包密码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      await AppAuth.instance.submitRecharge(code);
      _codeController.clear();
      await _load();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('已提交'),
          content: const Text(
            '充值申请已发送给管理员，核对红包金额后余额会自动更新，'
            '通常几分钟内处理完成。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on AppApiException catch (e) {
      if (mounted) {
        _toast(e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final wallet = _wallet;
    final recharges = wallet?.recharges ?? const <AppRecharge>[];
    final pendingCount = recharges.where((item) => item.pending).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('余额充值'),
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
            : _error != null && wallet == null
            ? _ErrorView(message: _error!, onRetry: () => unawaited(_load()))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    _BalanceCard(balance: wallet?.balance ?? 0),
                    if (pendingCount > 0) ...[
                      const SizedBox(height: 12),
                      _PendingHint(
                        count: pendingCount,
                        onRefresh: () => unawaited(_load()),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _SectionTitle(title: '提交支付宝口令'),
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '在支付宝发送口令红包后，把口令粘贴到下面提交。'
                              '管理员核对并领取红包后会在后台点「确认到账」，'
                              '余额自动增加，本页下拉即可看到最新状态。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _codeController,
                              enabled: !_submitting,
                              minLines: 2,
                              maxLines: 4,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(
                                labelText: '支付宝口令红包密码',
                                hintText: '把支付宝里复制的口令粘贴到这里',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _submitting
                                  ? null
                                  : () => unawaited(_submit()),
                              child: Text(_submitting ? '提交中…' : '提交'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _SectionTitle(title: '充值记录'),
                    const SizedBox(height: 8),
                    if (recharges.isEmpty)
                      _EmptyHint(text: '暂无充值记录')
                    else
                      for (final item in recharges) ...[
                        _RechargeCard(item: item),
                        const SizedBox(height: 8),
                      ],
                    if ((wallet?.guide ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text('充值说明', style: theme.textTheme.titleSmall),
                        childrenPadding: const EdgeInsets.only(bottom: 12),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              wallet!.guide.trim(),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.balance});

  final double balance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
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
        ],
      ),
    );
  }
}

class _PendingHint extends StatelessWidget {
  const _PendingHint({required this.count, required this.onRefresh});

  final int count;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.schedule_outlined,
              size: 18,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 $count 笔充值待管理员确认，确认后余额自动到账，无需重复提交。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
                height: 1.45,
              ),
            ),
          ),
          TextButton(
            onPressed: onRefresh,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

class _RechargeCard extends StatelessWidget {
  const _RechargeCard({required this.item});

  final AppRecharge item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final statusColor = item.approved
        ? Colors.green.shade600
        : item.rejected
        ? colorScheme.error
        : colorScheme.primary;
    final title = item.approved && item.amount > 0
        ? '充值 ¥${item.amount.toStringAsFixed(2)}'
        : item.rejected
        ? '充值未通过'
        : '支付宝口令充值';
    final statusText = item.statusLabel.isEmpty
        ? (item.pending
              ? '待确认到账'
              : item.approved
              ? '已到账'
              : item.status)
        : item.statusLabel;
    final note = item.note.trim();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '#R${item.id}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.createdAt.isEmpty ? '刚刚提交' : item.createdAt,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    statusText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusColor,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            if (item.pending) ...[
              const SizedBox(height: 8),
              Text(
                '管理员确认后余额自动到账，本页下拉可刷新状态。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
