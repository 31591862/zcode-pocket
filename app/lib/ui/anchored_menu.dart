// 锚定下拉菜单（2026-11-21 用户样式拍板）：替代 PopupMenuButton——
// SDK 的 _PopupMenuRoute 对菜单宽做 56px 步进取整（IntrinsicWidth
// stepWidth + min 224），无法内容自适应；本组件 LayerLink +
// CompositedTransformFollower 定位，宽度严格=最长项文字内联宽。
// 样式：白卡大圆角、描边分离（白底页面）、行高 54、16px 粗体、
// **按压胶囊高亮**（品牌色淡染、120ms easeOutCubic）；destructive
// 红文字；点菜单外任意处关闭。
import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/scheduler.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';

class AnchoredMenuItem {
  const AnchoredMenuItem({
    required this.value,
    required this.label,
    this.color,
    this.key,
    this.selected = false,
  });

  final String value;
  final String label;
  final Color? color;
  final Key? key;

  /// 当前值条目：胶囊常亮（值选择菜单语义，对应参考图的"跟随系统"行）。
  final bool selected;
}

/// 弹出锚定菜单；选择返回 value，点外关闭返回 null。
Future<String?> showAnchoredMenu(
  BuildContext context, {
  LayerLink? link,
  required List<AnchoredMenuItem> items,
  Alignment targetAnchor = Alignment.bottomRight,
  Alignment followerAnchor = Alignment.topRight,
  Offset offset = Offset.zero,
  Color? highlight,
  Color? background,
  Color? borderColor,

  /// 锚点（触发控件）的屏幕矩形——用于"下方放不下→向上翻转"的判位。
  Rect? anchorRect,

  /// 当前值条目的文字色（值选择菜单：selected 条目胶囊常亮+品牌色字）。
  Color? selectedTextColor,

  /// 卡片最大宽（长文案截断用；null=纯内容宽）。
  double? maxWidth,

  /// 点菜单外收起时的回调（**选择条目不触发**）——对齐 SDK
  /// PopupMenuButton 语义：收起≠选择，nullable 值菜单的"清除"只应由
  /// 明确选中的「继承默认」条目触发。
  VoidCallback? onDismissed,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future.value(null);
  final colors = context.colors;
  final bg = background ?? colors.card;
  final border = borderColor ?? colors.borderFaint;
  final hl = highlight ?? colors.brandAccent.withValues(alpha: 0.14);
  final radius = BorderRadius.circular(20);
  final completer = Completer<String?>();
  OverlayEntry? entry;

  // 放置翻转：锚点下方放不下（估算高 = 行高 62×项数 + 卡内边距）且
  // 上方放得下 → 向上展开（目标锚=顶右、跟随锚=底右）。
  var flip = false;
  if (anchorRect != null) {
    final menuHeight = items.length * 62 + 8; // 行高 54+胶囊外距 8×2 + 卡描边余量
    final screenH = MediaQuery.of(context).size.height;
    final below = screenH - anchorRect.bottom;
    final above = anchorRect.top;
    if (menuHeight > below && menuHeight <= above + screenH * 0.2) {
      flip = true;
    }
  }
  final tAnchor = flip ? Alignment.topRight : targetAnchor;
  final fAnchor = flip ? Alignment.bottomRight : followerAnchor;
  final off = flip ? Offset(0, -offset.dy) : offset;

  void close(String? value) {
    if (!completer.isCompleted) completer.complete(value);
    entry?.remove();
    entry = null;
  }

  // 翻转自纠：link 模式下首帧后量 follower 底缘，越屏即翻（重挂一次）。
  var flipChecked = false;
  final cardKey = GlobalKey();
  entry = OverlayEntry(
    builder: (overlayContext) {
      final media = MediaQuery.of(overlayContext);
      final screenH = media.size.height;
      final screenW = media.size.width;

      void scheduleFlipCheck() {
        if (flipChecked || link == null) return;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (entry == null || completer.isCompleted) return;
          final box = cardKey.currentContext?.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
          if (bottom > screenH - 8) {
            flipChecked = true;
            entry!.markNeedsBuild();
          }
        });
      }

      scheduleFlipCheck();

      // 菜单卡内容（link follower / rect 定位两种方式复用）。
      final menuCard = IntrinsicWidth(
        key: cardKey,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha:
                        Theme.of(overlayContext).brightness == Brightness.dark
                        ? 0.4
                        : 0.10,
                  ),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in items)
                    _AnchoredMenuTile(
                      key: item.key,
                      label: item.label,
                      color: item.selected
                          ? (selectedTextColor ?? item.color)
                          : item.color,
                      highlight: hl,
                      selected: item.selected,
                      onTap: () => close(item.value),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

      final menu = link != null
          ? CompositedTransformFollower(
              link: link,
              targetAnchor: flipChecked ? Alignment.topRight : tAnchor,
              followerAnchor: flipChecked ? Alignment.bottomRight : fAnchor,
              offset: flipChecked ? Offset.zero : off,
              showWhenUnlinked: false,
              child: menuCard,
            )
          : anchorRect != null
          ? Positioned(
              right: (screenW - anchorRect.right).clamp(8.0, screenW - 8.0),
              top: flip ? null : anchorRect.bottom + 4,
              bottom: flip ? screenH - anchorRect.top + 4 : null,
              child: menuCard,
            )
          : const SizedBox.shrink();
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                onDismissed?.call();
                close(null);
              },
            ),
          ),
          menu,
        ],
      );
    },
  );
  overlay.insert(entry!);
  return completer.future;
}

class _AnchoredMenuTile extends StatefulWidget {
  const _AnchoredMenuTile({
    required this.label,
    required this.highlight,
    required this.onTap,
    this.color,
    this.selected = false,
    super.key,
  });

  final String label;
  final Color? color;
  final Color highlight;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AnchoredMenuTile> createState() => _AnchoredMenuTileState();
}

class _AnchoredMenuTileState extends State<_AnchoredMenuTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // 行结构：外 8px（胶囊与卡缘间距）× 胶囊（46px 高、全圆、内衬 12px）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onPanCancel: () => setState(() => _pressed = false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          height: 46,
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            // 值选择菜单的当前值条目：胶囊常亮。
            color: _pressed || widget.selected
                ? widget.highlight
                : Colors.transparent,
            borderRadius: BorderRadius.circular(23),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
