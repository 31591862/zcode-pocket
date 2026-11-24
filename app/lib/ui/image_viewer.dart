import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/media_saver.dart';
import 'share_flow.dart' show shareBytesAsFile;
import 'top_notice.dart';

/// 全屏图片查看器（2026-11-24 用户参考样式拍板）：黑底（半透明透出会话）
/// + 顶部悬浮圆形按钮（左关闭 / 右分享保存）+ 居中文件名 + 双指缩放；
/// 点空白处关闭。替代原白卡 Dialog「截图 / 关闭」样式——display 截图与
/// 附件图片共用同一查看器。
Future<void> showImageViewer(
  BuildContext context, {
  required Uint8List bytes,
  required String title,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('关闭'),
    // 半透明黑：透出底层会话（参考图同款），点击遮罩关闭。
    barrierColor: Colors.black.withValues(alpha: 0.88),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (dialogContext, _, _) =>
        _ImageViewer(bytes: bytes, title: title),
    transitionBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.bytes, required this.title});

  final Uint8List bytes;
  final String title;

  /// 下载（2026-11-24 用户拍板：此按钮是下载不是分享）：Android 存
  /// 系统相册（MediaStore）；其他平台/失败回退系统分享面板（可另存）。
  Future<void> _download(BuildContext context) async {
    final saved = await saveImageToGallery(bytes, name: title);
    if (!context.mounted) return;
    if (saved != null) {
      TopNotice.show(
        message: tr('已保存到相册'),
        duration: const Duration(seconds: 2),
      );
      return;
    }
    await shareBytesAsFile(context, title, bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Stack(
          key: const ValueKey('image-viewer'),
          children: [
            Positioned.fill(
              // 单击图片/空白关闭（相册式交互；双指缩放/拖动不触发
              // tap——多指或位移手势与 tap 可区分）。barrier 被全屏
              // 内容拦截，不能依赖 barrierDismissible。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: RepaintBoundary(
                      child: Image.memory(bytes, gaplessPlayback: true),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  _CircleIconButton(
                    key: const ValueKey('image-viewer-close'),
                    icon: Icons.close,
                    tooltip: tr('关闭'),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      translate: false,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _CircleIconButton(
                    key: const ValueKey('image-viewer-download'),
                    icon: Icons.download_outlined,
                    tooltip: tr('保存到手机'),
                    onTap: () => _download(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部悬浮圆形按钮（深色半透明底 + 白色图标，参考图同款）。
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 21, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
