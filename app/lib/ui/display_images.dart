// 工具行 display 图片（2026-11-20 对齐桌面）：
// ① mcp node_repl 浏览器截图等挂在工具行
//    row.display = {kind: 'node_repl_images', images: [{base64, mimeType}]}
//    ——此前手机端完全不消费（真机 PvZ 会话成果截图不显示）；
// ② 展开态：每行工具下内联缩略图；收起态：轮内「成果截图」条
//    （固定尺寸槽位——图片异步解码前后布局不跳，贴底列表安全）。
// 解码缓存：每张 ~140KB、行随流式/滚动反复重建——按 (rowId,index,len)
// 做 16 条 LRU，Image 侧 cacheWidth 限解码内存。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';

/// row.display 是否为可渲染的图片组。
bool hasDisplayImages(Map<String, dynamic> row) {
  final display = row['display'];
  if (display is! Map || '${display['kind']}' != 'node_repl_images') {
    return false;
  }
  final images = display['images'];
  return images is List &&
      images.any(
        (i) =>
            i is Map &&
            '${i['base64'] ?? ''}'.isNotEmpty &&
            '${i['mimeType'] ?? 'image/'}'.startsWith('image/'),
      );
}

class _BytesCache {
  static const _max = 16;
  static final Map<String, Uint8List> _map = {};

  static Uint8List? get(String key) => _map[key];

  static void put(String key, Uint8List bytes) {
    if (_map.length >= _max) _map.remove(_map.keys.first);
    _map[key] = bytes;
  }
}

Uint8List? _bytesOf(int rowId, int index, String base64) {
  final key = '$rowId:$index:${base64.length}';
  final cached = _BytesCache.get(key);
  if (cached != null) return cached;
  try {
    final bytes = base64Decode(base64);
    _BytesCache.put(key, bytes);
    return bytes;
  } on FormatException {
    return null;
  }
}

/// 大图弹窗（展开态缩略图 / 收起态成果条共用）。
void openDisplayImage(BuildContext context, Uint8List bytes) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text('截图', style: TextStyle(fontSize: AppType.uiCaption)),
          ),
          Flexible(
            child: InteractiveViewer(
              maxScale: 4,
              child: RepaintBoundary(
                child: Image.memory(bytes, gaplessPlayback: true),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}

/// 工具行内缩略图条（展开态，每行工具各自渲染）。
class ToolDisplayImages extends StatelessWidget {
  final int rowId;
  final Map<dynamic, dynamic> display;

  const ToolDisplayImages({
    super.key,
    required this.rowId,
    required this.display,
  });

  List<Uint8List> _images() {
    final images = display['images'];
    if (images is! List) return const [];
    final out = <Uint8List>[];
    for (var i = 0; i < images.length; i++) {
      final im = images[i];
      if (im is! Map) continue;
      if (!'${im['mimeType'] ?? 'image/'}'.startsWith('image/')) continue;
      final bytes = _bytesOf(rowId, i, '${im['base64'] ?? ''}');
      if (bytes == null) continue;
      out.add(bytes);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final images = _images();
    if (images.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 24, right: 2, bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < images.length; i++)
            InkWell(
              key: ValueKey('display-image-$rowId-$i'),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () => openDisplayImage(context, images[i]),
              child: Container(
                constraints: const BoxConstraints(
                  maxWidth: 220,
                  maxHeight: 140,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: context.colors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(
                  images[i],
                  cacheWidth: 440,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 收起态「成果截图」条：只取**最后一个带图的工具行**（交付截图）——
/// 思考/调试过程中产生的截图不在收起态展示（2026-11-20 真机对照桌面：
/// 结尾位置只显示最后一张交付截图），过程截图仍可在展开态逐行查看。
/// 固定尺寸槽位（解码前后布局恒定），最多 [maxCount] 张，超出「+N」。
class TurnDisplayImages extends StatelessWidget {
  static const double slotHeight = 116;
  static const double slotWidth = 154;

  final List<Map<String, dynamic>> rows;
  final int maxCount;

  const TurnDisplayImages({super.key, required this.rows, this.maxCount = 4});

  @override
  Widget build(BuildContext context) {
    // 只保留最后一个带图工具行的图片（交付截图）；过程截图不汇总。
    var found = const <Uint8List>[];
    for (final row in rows) {
      final display = row['display'];
      if (display is! Map || '${display['kind']}' != 'node_repl_images') {
        continue;
      }
      final images = display['images'];
      if (images is! List) continue;
      final rowId = intOf(row['rowId']) ?? -1;
      final rowImages = <Uint8List>[];
      for (var i = 0; i < images.length; i++) {
        final im = images[i];
        if (im is! Map) continue;
        if (!'${im['mimeType'] ?? 'image/'}'.startsWith('image/')) continue;
        final bytes = _bytesOf(rowId, i, '${im['base64'] ?? ''}');
        if (bytes == null) continue;
        rowImages.add(bytes);
      }
      if (rowImages.isNotEmpty) found = rowImages;
    }
    if (found.isEmpty) return const SizedBox.shrink();
    final visible = found.take(maxCount).toList();
    final hidden = found.length - visible.length;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < visible.length; i++)
          InkWell(
            key: ValueKey('turn-display-image-$i'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => openDisplayImage(context, visible[i]),
            child: Container(
              width: slotWidth,
              height: slotHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: context.colors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.memory(
                visible[i],
                cacheWidth: 440,
                gaplessPlayback: true,
                fit: BoxFit.cover,
              ),
            ),
          ),
        if (hidden > 0)
          Container(
            width: 44,
            height: slotHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.colors.card,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: context.colors.border),
            ),
            child: Text(
              '+$hidden',
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
      ],
    );
  }
}
