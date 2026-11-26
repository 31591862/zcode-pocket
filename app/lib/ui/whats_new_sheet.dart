// 版本更新说明弹层（What's New）：
// - 老用户升级进入任务主页时自动弹出一次，或从「设置 → 关于 → 本版更新说明」随时回看；
// - 仅对视觉变化显著的重点项展示精选 WebP 截图（浅/深主题自动匹配、可点击全屏放大），
//   纯文字即可说清的改动保持简洁条目，避免冗长打扰。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../core/whats_new.dart';

/// 打开「版本更新说明」底部弹层。
Future<void> showWhatsNewSheet(
  BuildContext context, {
  WhatsNewRelease release = kCurrentWhatsNew,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => WhatsNewSheet(release: release),
  );
}

class WhatsNewSheet extends StatelessWidget {
  const WhatsNewSheet({super.key, this.release = kCurrentWhatsNew});

  final WhatsNewRelease release;

  IconData _iconFor(String name) => switch (name) {
    'usage' => Icons.data_usage_outlined,
    'workflow' => Icons.account_tree_outlined,
    'vision' => Icons.visibility_outlined,
    'order' => Icons.reorder,
    'settings' => Icons.tune,
    'window' => Icons.picture_in_picture_alt_outlined,
    _ => Icons.auto_awesome_outlined,
  };

  void _openFullImage(BuildContext context, String assetPath, String title) {
    final c = context.colors;
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        fontWeight: FontWeight.w600,
                        color: c.foreground,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('whats-new-preview-close'),
                    tooltip: tr('关闭'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.borderFaint),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(dialogCtx).height * 0.72,
                ),
                child: InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 3.0,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: Image.asset(
                        assetPath,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightItem(
    BuildContext context,
    int index,
    WhatsNewHighlight item,
  ) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = item.assetForBrightness(isDark: isDark);

    return Padding(
      key: ValueKey('whats-new-item-$index'),
      padding: EdgeInsets.only(top: index == 0 ? 4 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: c.brandAccent.withValues(alpha: AppAlpha.faint),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  _iconFor(item.iconName),
                  size: 16,
                  color: c.brandAccentBright,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: TextStyle(
                        fontSize: AppType.uiBase,
                        fontWeight: FontWeight.w600,
                        color: c.foreground,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.description,
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        height: 1.4,
                        color: c.foregroundSubtle,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (asset != null) ...[
            const SizedBox(height: 10),
            Image.asset(
              asset,
              fit: BoxFit.contain,
              frameBuilder: (ctx, child, frame, wasSync) => GestureDetector(
                key: ValueKey('whats-new-shot-$index'),
                onTap: () => _openFullImage(context, asset, item.title),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(
                      color: isDark ? c.borderHover : c.border,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Center(child: child),
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: c.card.withValues(alpha: AppAlpha.strong),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border.all(color: c.borderFaint),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.zoom_in,
                                size: 13,
                                color: c.foregroundSubtle,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '点击查看大图',
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: c.foregroundSubtle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.84,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '已更新到 v${release.version}',
                              style: TextStyle(
                                fontSize: AppType.uiLg,
                                fontWeight: FontWeight.w600,
                                color: c.foreground,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: c.brandAccent.withValues(
                                  alpha: AppAlpha.faint,
                                ),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                              child: Text(
                                '更新说明',
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  fontWeight: FontWeight.w500,
                                  color: c.brandAccentBright,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          release.headline,
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: c.foregroundSubtle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('whats-new-close'),
                    tooltip: tr('关闭'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.borderFaint),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < release.highlights.length; i++)
                    _buildHighlightItem(context, i, release.highlights[i]),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('whats-new-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.brand,
                    foregroundColor: c.onBrand,
                    minimumSize: const Size(double.infinity, 42),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('知道了'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
