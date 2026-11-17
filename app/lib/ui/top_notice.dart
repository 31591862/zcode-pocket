import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'settings_style.dart';

/// 顶部轻提示（2026-11-17 用户拍板）：带动作的提示从顶部弹出（Eta 卡
/// 风格），替代 SnackBar。
///
/// 缘起：Flutter 3.47 起 SnackBar 带 action 默认 `persist=true`（永驻，
/// duration 到时短路不关闭）——旧"显式 3s"语义失效，用户实测归档提示
/// 不消失。自绘 Overlay 卡片恢复"到时自动退场 + 动作按钮窗口期内可点"
/// 语义，且视觉与设置/抽屉的白卡体系一致。
///
/// 单例：同时最多一条，新提示直接顶掉旧条（无退场动画）。
/// 退场方式：到时 / 点动作 / 点卡片主体，三选一。
class TopNotice {
  TopNotice._();

  static OverlayEntry? _entry;
  static _TopNoticeCardState? _state;

  static void show(
    BuildContext context, {
    required String message,
    IconData icon = Icons.info_outline,
    Color? iconColor,
    Key? key,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _discard();
    // 先声明后赋值：onDismissed 闭包要读同一变量（identical 防新条
    // 顶替后旧条退场回调误删新条）。
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (_) => _TopNoticeCard(
        key: key,
        message: message,
        icon: icon,
        iconColor: iconColor,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration,
        onDismissed: () {
          if (identical(_entry, entry)) {
            _entry?.remove();
            _entry = null;
            _state = null;
          }
        },
        onStateReady: (state) => _state = state,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 立即摘除旧条（顶替场景不做退场动画，避免新旧两卡叠影）。
  static void _discard() {
    _state = null;
    _entry?.remove();
    _entry = null;
  }

  /// 动画退场（动作按钮/卡片点按时用；无在场条则 no-op）。
  static void dismiss() {
    final state = _state;
    if (state != null) {
      state.dismiss();
      return;
    }
    _discard();
  }
}

class _TopNoticeCard extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color? iconColor;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  final VoidCallback onDismissed;
  final ValueChanged<_TopNoticeCardState>? onStateReady;

  const _TopNoticeCard({
    super.key,
    required this.message,
    required this.icon,
    required this.iconColor,
    required this.actionLabel,
    required this.onAction,
    required this.duration,
    required this.onDismissed,
    required this.onStateReady,
  });

  @override
  State<_TopNoticeCard> createState() => _TopNoticeCardState();
}

class _TopNoticeCardState extends State<_TopNoticeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.onStateReady?.call(this);
    _controller.forward();
    _timer = Timer(widget.duration, dismiss);
  }

  void dismiss() {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: SafeArea(
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -1),
            end: Offset.zero,
          ).animate(_curve),
          child: FadeTransition(
            opacity: _curve,
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? kSettingsCardDark : kSettingsCardLight,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black
                        .withValues(alpha: isDark ? 0.4 : 0.10),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              // 提示主体可点提前退场（动作按钮独立在下，互不干扰）。
              child: Material(
                type: MaterialType.transparency,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                  child: Row(
                    children: [
                      Icon(
                        widget.icon,
                        size: 20,
                        color: widget.iconColor ?? kSettingsIconBlue,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: dismiss,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              widget.message,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: AppType.uiBase),
                            ),
                          ),
                        ),
                      ),
                      if (widget.actionLabel != null)
                        TextButton(
                          onPressed: () {
                            final action = widget.onAction;
                            dismiss();
                            action?.call();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: context.colors.brandAccent,
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(widget.actionLabel!),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
