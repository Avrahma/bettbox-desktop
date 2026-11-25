import 'dart:async';
import 'dart:math' as math;

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

/// 套餐分类：选项卡顺序固定为 年付 → 定制 → 月付。
enum _PlanCategory {
  yearly('年付'),
  custom('定制'),
  monthly('月付');

  const _PlanCategory(this.label);

  final String label;
}

/// 按名称与周期归类套餐：「定制」优先判断，其次按周期区分年付与月付。
_PlanCategory _categoryOfPlan(AppPlan plan) {
  final text = '${plan.tierLabel}${plan.name}';
  if (text.contains('定制') ||
      text.contains('专属') ||
      text.contains('私人') ||
      text.contains('家宽')) {
    return _PlanCategory.custom;
  }
  if (plan.months <= 0 || plan.months % 12 == 0) {
    return _PlanCategory.yearly;
  }
  if (text.contains('年付') || text.contains('包年') || text.contains('年度')) {
    return _PlanCategory.yearly;
  }
  return _PlanCategory.monthly;
}

class _ShopPageState extends State<ShopPage>
    with SingleTickerProviderStateMixin {
  AppShopData? _data;
  String? _error;
  bool _loading = true;
  int? _buyingPlanId;
  bool _renewing = false;

  /// 套餐分类选项卡：年付 → 定制 → 月付。
  late final TabController _tabController = TabController(
    length: _PlanCategory.values.length,
    vsync: this,
  )..addListener(_onTabChanged);

  void _onTabChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_showWelcomeNotice());
      }
    });
  }

  /// 进入套餐中心时的公告弹窗（同机场公告弹窗风格）。
  Future<void> _showWelcomeNotice() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        const notices = <String>[
          '全站仅支持余额支付，余额通过支付宝口令红包充值，管理员确认到账后余额自动更新。',
          '余额充足即可下单，购买成功后订阅自动下发到配置页，无需手动导入。',
          '套餐为虚拟商品，开通后不支持退款，请确认周期与线路后再购买。',
          '家宽网络等定制类套餐按定制周期交付，具体以客服确认为准。',
        ];
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
          contentPadding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
          actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          title: Row(
            children: [
              Icon(Icons.campaign_outlined, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text('购买须知', style: theme.textTheme.titleMedium),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < notices.length; i++) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${i + 1}.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            notices[i],
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.55,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (i != notices.length - 1) const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('我知道了'),
            ),
          ],
        );
      },
    );
  }

  List<AppPlan> _plansIn(int tabIndex, List<AppPlan> plans) {
    final category = _PlanCategory.values[
        tabIndex.clamp(0, _PlanCategory.values.length - 1)];
    final result =
        plans.where((plan) => _categoryOfPlan(plan) == category).toList()
          ..sort((a, b) => a.price.compareTo(b.price));
    return result;
  }

  /// 套餐横向排列：按可用宽度自适应 3/2/1 列，同排卡片等高。
  Widget _buildPlanTiles(AppShopData data) {
    final plans = _plansIn(_tabController.index, data.plans);
    if (plans.isEmpty) {
      return const _EmptyHint(text: '该分类暂无可购买套餐，看看其它分类或联系客服');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final columns = maxWidth >= 960
            ? 3
            : maxWidth >= 620
            ? 2
            : 1;
        const spacing = 10.0;
        final tileWidth = (maxWidth - spacing * (columns - 1)) / columns;
        final children = <Widget>[];
        for (var start = 0; start < plans.length; start += columns) {
          final chunk = plans.sublist(
            start,
            math.min(start + columns, plans.length),
          );
          if (start > 0) children.add(const SizedBox(height: spacing));
          children.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < chunk.length; i++) ...[
                    if (i > 0) const SizedBox(width: spacing),
                    SizedBox(
                      width: tileWidth,
                      child: _PlanCard(
                        plan: chunk[i],
                        balance: data.balance,
                        busy: _buyingPlanId != null,
                        onBuy: () => unawaited(_buy(chunk[i])),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      },
    );
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
    final couponController = TextEditingController();
    var appliedCode = '';
    var discount = 0.0;
    var payPrice = plan.price;
    String? couponHint;
    var couponError = false;
    var checking = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final shortfall = double.parse(
              (payPrice - balance).toStringAsFixed(2),
            );

            Future<void> applyCoupon() async {
              final code = couponController.text.trim();
              if (code.isEmpty) {
                setDialogState(() {
                  couponHint = '请输入优惠码';
                  couponError = true;
                });
                return;
              }
              setDialogState(() {
                checking = true;
                couponHint = null;
                couponError = false;
              });
              try {
                final quote = await AppAuth.instance.checkCoupon(
                  planId: plan.id,
                  code: code,
                );
                setDialogState(() {
                  checking = false;
                  appliedCode = quote.code;
                  discount = quote.discount;
                  payPrice = quote.finalPrice;
                  couponError = false;
                  couponHint =
                      '已使用 ${quote.code}，优惠 ¥${quote.discount.toStringAsFixed(2)}';
                });
              } on AppApiException catch (e) {
                setDialogState(() {
                  checking = false;
                  appliedCode = '';
                  discount = 0;
                  payPrice = plan.price;
                  couponError = true;
                  couponHint = e.message;
                });
              }
            }

            return AlertDialog(
              title: Text('购买 ${plan.name}'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(theme, '套餐', plan.name),
                    _kv(theme, '周期', plan.periodText),
                    _kv(theme, '套餐原价', '¥${plan.price.toStringAsFixed(2)}'),
                    if (discount > 0)
                      _kv(theme, '优惠金额', '-¥${discount.toStringAsFixed(2)}'),
                    _kv(theme, '应付金额', '¥${payPrice.toStringAsFixed(2)}'),
                    _kv(theme, '当前余额', '¥${balance.toStringAsFixed(2)}'),
                    const SizedBox(height: 10),
                    Text(
                      '优惠码',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: couponController,
                            enabled: !checking,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '输入优惠码（可选）',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 12,
                              ),
                            ),
                            onChanged: (value) {
                              if (appliedCode.isEmpty) {
                                return;
                              }
                              if (value.trim().toUpperCase() != appliedCode) {
                                setDialogState(() {
                                  appliedCode = '';
                                  discount = 0;
                                  payPrice = plan.price;
                                  couponHint = null;
                                  couponError = false;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: checking ? null : applyCoupon,
                          child: checking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('使用'),
                        ),
                      ],
                    ),
                    if (couponHint != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        couponHint!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: couponError
                              ? colorScheme.error
                              : colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      shortfall > 0
                          ? '余额不足，还差 ¥${shortfall.toStringAsFixed(2)}，需要先充值'
                          : payPrice <= 0
                          ? '优惠后无需支付，确认后立即开通订阅'
                          : '支付后余额 ¥${(balance - payPrice).toStringAsFixed(2)}，'
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
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: checking
                      ? null
                      : () => Navigator.of(dialogContext).pop(true),
                  child: Text(
                    shortfall > 0
                        ? '去充值'
                        : (payPrice <= 0 ? '免费开通' : '余额支付'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    couponController.dispose();
    if (confirmed != true) {
      return;
    }
    final shortfallAfter = double.parse(
      (payPrice - balance).toStringAsFixed(2),
    );
    if (shortfallAfter > 0) {
      await _openRecharge();
      return;
    }
    setState(() => _buyingPlanId = plan.id);
    try {
      final result = await AppAuth.instance.purchaseWithBalance(
        plan.id,
        couponCode: appliedCode,
      );
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
            '${discount > 0 ? '优惠：-¥${discount.toStringAsFixed(2)}（$appliedCode）\n' : ''}'
            '实付：¥${payPrice.toStringAsFixed(2)}\n'
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

  /// 续费当前订阅：余额支付，余额不足时引导去充值。
  Future<void> _openRenew() async {
    final data = _data;
    if (data == null || _renewing) {
      return;
    }
    final renewal = data.renewal;
    if (renewal == null) {
      _toast('当前没有可续费的订阅，请先选择套餐购买');
      return;
    }
    if (renewal.permanent) {
      _toast('永久套餐无需续费');
      return;
    }
    final balance = data.balance;
    final shortfall = double.parse(
      (renewal.price - balance).toStringAsFixed(2),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: const Text('续费套餐'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(theme, '套餐', renewal.planName),
              _kv(theme, '续费周期', renewal.periodText),
              _kv(
                theme,
                '当前到期',
                renewal.expiresOn.isEmpty
                    ? '—'
                    : '${renewal.expiresOn}${renewal.expired ? '（已到期）' : ''}',
              ),
              _kv(
                theme,
                '续费后到期',
                renewal.newExpiresOn.isEmpty ? '以订阅页为准' : renewal.newExpiresOn,
              ),
              _kv(theme, '应付金额', '¥${renewal.price.toStringAsFixed(2)}'),
              _kv(theme, '当前余额', '¥${balance.toStringAsFixed(2)}'),
              const SizedBox(height: 8),
              Text(
                shortfall > 0
                    ? '余额不足，还差 ¥${shortfall.toStringAsFixed(2)}，需要先充值'
                    : '支付后余额 ¥${(balance - renewal.price).toStringAsFixed(2)}，'
                          '确认后立即续费、到期日顺延',
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
    setState(() => _renewing = true);
    try {
      final result = await AppAuth.instance.renewWithBalance(
        allocationId: renewal.allocationId,
      );
      await AppAuth.instance.refresh();
      await _load();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('续费成功'),
          content: Text(
            '${result.message}\n\n套餐：${renewal.planName}\n'
            '到期时间：${result.expiresOn.isEmpty ? '以订阅页为准' : result.expiresOn}\n'
            '当前余额：¥${result.balance.toStringAsFixed(2)}\n\n'
            '订阅链接已自动更新，请在配置页重新获取订阅。',
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
        setState(() => _renewing = false);
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
                    _ExpiryBanner(
                      renewal: data?.renewal,
                      busy: _renewing,
                      onRenew: () => unawaited(_openRenew()),
                    ),
                    _BalanceBar(
                      balance: data?.balance ?? 0,
                      renewal: data?.renewal,
                      busy: _renewing,
                      onRecharge: () => unawaited(_openRecharge()),
                      onRenew: () => unawaited(_openRenew()),
                    ),
                    const SizedBox(height: 18),
                    _SectionTitle(title: '选择套餐'),
                    const SizedBox(height: 10),
                    if ((data?.plans ?? const <AppPlan>[]).isEmpty)
                      _EmptyHint(text: '暂无可购买套餐，请联系客服')
                    else ...[
                      _PlanTabBar(controller: _tabController),
                      const SizedBox(height: 12),
                      _buildPlanTiles(data!),
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

/// 套餐分类选项卡：年付套餐 / 定制套餐 / 月付套餐。
class _PlanTabBar extends StatelessWidget {
  const _PlanTabBar({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: controller,
        indicator: BoxDecoration(
          color: colorScheme.primary,
          borderRadius: BorderRadius.circular(9),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: EdgeInsets.zero,
        dividerColor: Colors.transparent,
        splashBorderRadius: BorderRadius.circular(9),
        overlayColor: WidgetStatePropertyAll(
          colorScheme.primary.withValues(alpha: 0.08),
        ),
        labelColor: colorScheme.onPrimary,
        unselectedLabelColor: colorScheme.onSurfaceVariant,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: theme.textTheme.labelLarge,
        labelPadding: EdgeInsets.zero,
        tabs: [
          for (final category in _PlanCategory.values)
            Tab(
              height: 34,
              child: Text(
                '${category.label}套餐',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
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

/// 到期前 3 天起在套餐中心顶部提示续费；已过期时提示续费恢复。
class _ExpiryBanner extends StatelessWidget {
  const _ExpiryBanner({
    required this.renewal,
    required this.busy,
    required this.onRenew,
  });

  final AppRenewal? renewal;
  final bool busy;
  final VoidCallback onRenew;

  @override
  Widget build(BuildContext context) {
    final item = renewal;
    if (item == null || item.permanent) {
      return const SizedBox.shrink();
    }
    final days = item.daysLeft;
    final expired = item.expired || days < 0;
    if (!expired && days > 3) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final expire = item.expiresOn.isEmpty ? '到期日未知' : item.expiresOn;
    final text = expired
        ? '订阅已于 $expire 到期，续费后立即恢复使用'
        : days <= 0
        ? '订阅今天（$expire）到期，请及时续费'
        : '订阅还剩 $days 天到期（$expire），请及时续费';
    final fg = colorScheme.onErrorContainer;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.notifications_active_outlined, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  expired ? '订阅已到期' : '续费提醒',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fg.withValues(alpha: 0.9),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: busy ? null : onRenew,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              backgroundColor: fg,
              foregroundColor: colorScheme.errorContainer,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('立即续费'),
          ),
        ],
      ),
    );
  }
}

class _BalanceBar extends StatelessWidget {
  const _BalanceBar({
    required this.balance,
    required this.renewal,
    required this.busy,
    required this.onRecharge,
    required this.onRenew,
  });

  final double balance;
  final AppRenewal? renewal;
  final bool busy;
  final VoidCallback onRecharge;
  final VoidCallback onRenew;

  String get _renewHint {
    final item = renewal;
    if (item == null) {
      return '暂无可续费订阅';
    }
    if (item.permanent) {
      return '永久套餐，无需续费';
    }
    final expire = item.expiresOn.isEmpty ? '到期日未知' : '${item.expiresOn} 到期';
    return '${item.planName} · $expire';
  }

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
        crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 4),
                Text(
                  _renewHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer.withValues(
                      alpha: 0.75,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 88,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.tonal(
                  onPressed: busy ? null : onRenew,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('续费'),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: busy ? null : onRecharge,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colorScheme.onPrimaryContainer,
                    side: BorderSide(
                      color: colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.35,
                      ),
                    ),
                  ),
                  child: const Text('充值'),
                ),
              ],
            ),
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
