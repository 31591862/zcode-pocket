import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;

import '../core/theme.dart';

/// 图片附件缩略图（2026-11-24 用户拍板）：用户气泡附件行——图片类
/// 附件显示缩略图（72×72 圆角，异步读字节，加载中骨架，失败回退
/// 「回形针」占位）。点击仍走原附件打开（全屏查看器）。
class AttachmentThumb extends StatefulWidget {
  const AttachmentThumb({
    super.key,
    required this.load,
    required this.fileName,
    this.onTap,
  });

  /// 读取原始字节（页面侧带缓存/去重；null=读取失败）。
  final Future<Uint8List?> Function() load;
  final String fileName;
  final VoidCallback? onTap;

  @override
  State<AttachmentThumb> createState() => _AttachmentThumbState();
}

class _AttachmentThumbState extends State<AttachmentThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  /// 图片实际宽高比（宽/高；null=未解析/失败——回退方形占位）。
  /// 2026-11-24 用户拍板：缩略图与图片实际比例一致（原 72×72 方形
  /// cover 会裁掉宽图/长图两侧）。
  double? _aspect;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.load();
    double? aspect;
    if (bytes != null) {
      try {
        // ImageDescriptor 只读编码头（毫秒级），不整图解码。
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width > 0 && descriptor.height > 0) {
          aspect = descriptor.width / descriptor.height;
        }
        descriptor.dispose();
        buffer.dispose();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
      _aspect = aspect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    // 按实际比例填充 220×240 框（2026-11-24 用户反馈「太小」）：
    // 竖屏截图高度可到 240、横图宽度可到 220、全景图受宽度收口——
    // 均为等比缩放，不裁切。加载前占位固定 160×120（比例未知）。
    const maxW = 220.0;
    const maxH = 240.0;
    var thumbW = 160.0;
    var thumbH = 120.0;
    final aspect = _aspect;
    if (bytes != null && aspect != null && aspect > 0) {
      final scale = math.min(maxW / aspect, maxH);
      thumbW = aspect * scale;
      thumbH = scale;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: thumbW,
          height: thumbH,
          child: bytes != null
              ? Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: 240,
                )
              : Container(
                  color: context.colors.sidebar,
                  alignment: Alignment.center,
                  child: Icon(
                    _failed ? Icons.broken_image_outlined : Icons.image_outlined,
                    size: 22,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
        ),
      ),
    );
  }
}
