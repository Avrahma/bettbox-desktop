import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// 首页「启动开关」方形小卡（约 1:1），用于压缩版快速面板。
class QuickStartSquare extends ConsumerStatefulWidget {
  const QuickStartSquare({super.key});

  @override
  ConsumerState<QuickStartSquare> createState() => _QuickStartSquareState();
}

class _QuickStartSquareState extends ConsumerState<QuickStartSquare> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    final newState =
        ref.read(isSmartStoppedProvider) || ref.read(runTimeProvider) == null;
    setState(() => _busy = true);
    try {
      await globalState.appController.updateStatus(newState);
    } catch (e) {
      commonPrint.error('updateStatus failed: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _noProfileTip() {
    unawaited(
      globalState.showMessage(
        title: '暂无可用配置',
        message: const TextSpan(
          text: '当前账号未开通套餐，无法启动。请先在首页购买套餐，开通后配置会自动导入。',
        ),
        cancelable: false,
      ),
    );
  }

  String _formatRunTime(int? timeStamp) {
    if (timeStamp == null) return '00:00:00';
    final diff = timeStamp / 1000;
    var inHours = (diff / 3600).floor();
    final inMinutes = (diff / 60 % 60).floor();
    final inSeconds = (diff % 60).floor();
    if (inHours > 999) inHours = 999;
    final hourStr = inHours < 100
        ? inHours.toString().padLeft(2, '0')
        : inHours.toString().padLeft(3, '0');
    return '$hourStr:${inMinutes.toString().padLeft(2, '0')}:${inSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(startButtonSelectorStateProvider);
    final isSmartStopped = ref.watch(isSmartStoppedProvider);
    final isStart = ref.watch(runTimeProvider.select((time) => time != null));
    final colorScheme = context.colorScheme;
    final canPress = state.isInit && state.hasProfile && !_busy;
    final hasNoProfile = state.isInit && !state.hasProfile && !_busy;
    final displayStart = isStart && !isSmartStopped;
    final onPressed = canPress
        ? _toggle
        : hasNoProfile
        ? _noProfileTip
        : null;

    return CommonCard(
      onPressed: onPressed,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary.withValues(
                    alpha: displayStart ? 0.18 : 0.1,
                  ),
                ),
                child: AppIcon(
                  displayStart ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<int>(
                valueListenable: dashboardRefreshManager.tick1s,
                builder: (_, _, _) => Text(
                  displayStart
                      ? _formatRunTime(ref.read(runTimeProvider))
                      : hasNoProfile
                      ? '未开通'
                      : '未启动',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// 首页「网络检测」方形小卡（约 1:1），显示出口地区并用原生弹窗查看 IP 详情。
class QuickNetworkSquare extends ConsumerWidget {
  const QuickNetworkSquare({super.key});

  String _emoji(String countryCode) {
    final code = countryCode.toUpperCase();
    if (code.length != 2) return '';
    final first = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final second = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(first) + String.fromCharCode(second);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    return ValueListenableBuilder<NetworkDetectionState>(
        valueListenable: detectionState.state,
        builder: (_, state, _) {
          final ipInfo = state.ipInfo;
          final flag = ipInfo == null ? '' : _emoji(ipInfo.countryCode);
          final text = ipInfo == null
              ? (state.isLoading ? '检测中' : '重试')
              : (ipInfo.country?.isNotEmpty == true
                    ? ipInfo.country!
                    : ipInfo.ip);
          return CommonCard(
            onPressed: ipInfo == null
                ? detectionState.manualRefresh
                : () => showIpDetailDialog(
                    context,
                    ipInfo.ip,
                    preloaded: ipInfo,
                    showRisk: detectionState.riskyIp.value == ipInfo.ip,
                  ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (flag.isNotEmpty)
                    Text(
                      flag,
                      style: TextStyle(
                        fontSize: 22,
                        fontFamily: FontFamily.twEmoji.value,
                        fontFamilyFallback: const ['Twemoji'],
                      ),
                    )
                  else
                    state.isLoading
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colorScheme.primary,
                            ),
                          )
                        : AppIcon(
                            Icons.network_check,
                            size: 20,
                            color: colorScheme.onSurfaceVariant,
                          ),
                  const SizedBox(height: 6),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: context.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
    );
  }
}
