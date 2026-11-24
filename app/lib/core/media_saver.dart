import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 图片保存到系统相册（2026-11-24 图片查看器下载按钮）：Android 原生
/// MediaStore（Pictures/ZCodePocket，API29+ 免权限；<29 存应用 Pictures
/// 兜底）。其他平台/失败返回 null——调用方回退系统分享面板。
const _channel = MethodChannel('companion/media_save');

/// 按字节头嗅探 MIME（查看器数据源无信使 MIME：display 截图/附件）。
String sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

Future<String?> saveImageToGallery(
  Uint8List bytes, {
  required String name,
}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('saveImage', {
      'bytes': bytes,
      'name': name,
      'mime': sniffImageMime(bytes),
    });
    return res?['path'] as String?;
  } catch (_) {
    return null;
  }
}
