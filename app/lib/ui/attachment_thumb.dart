import 'dart:typed_data';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.load();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 72,
          height: 72,
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
