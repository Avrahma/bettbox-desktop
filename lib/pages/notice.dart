import 'package:bett_box/common/app_notice.dart';
import 'package:material_ui/material_ui.dart';

/// 客户端公告弹窗，视觉与套餐中心「购买须知」保持一致。
///
/// 由首页账户卡的「公告」入口或新公告自动弹出时调用。
Future<void> showAppNoticeDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final colorScheme = theme.colorScheme;
      final notice = AppNoticeCenter.instance.notice;
      final rawTitle = notice?.title.trim() ?? '';
      final title = rawTitle.isEmpty ? '公告' : rawTitle;
      final content = notice?.content.trim() ?? '';
      final timeText = _formatNoticeTime(notice?.publishedAt ?? '');

      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        title: Row(
          children: [
            Icon(Icons.campaign_outlined, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (timeText.isNotEmpty) ...[
                  Text(
                    timeText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                SelectableText(
                  content.isEmpty ? '暂无公告内容' : content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
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

String _formatNoticeTime(String raw) {
  final time = DateTime.tryParse(raw)?.toLocal();
  if (time == null) {
    return '';
  }
  String two(int value) => value.toString().padLeft(2, '0');
  return '发布于 ${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
