// 全屏图片查看器（2026-11-24 用户参考样式）：黑底 + 顶部圆形按钮
// （关闭/分享）+ 居中文件名 + 缩放。锁：打开可见三要素、点关闭收起、
// 点遮罩收起。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/image_viewer.dart';

// 1x1 透明白点 PNG（最小合法图片字节）。
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _host({void Function(BuildContext)? onOpen}) => MaterialApp(
  theme: buildAppTheme(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => onOpen?.call(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('打开查看器：文件名/关闭/分享在树，点关闭收起', (tester) async {
    await tester.pumpWidget(
      _host(
        onOpen: (context) =>
            showImageViewer(context, bytes: _png, title: 'scaled_1.jpg'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-viewer')), findsOneWidget);
    expect(find.text('scaled_1.jpg'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-viewer-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-viewer-download')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('image-viewer-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-viewer')), findsNothing);
  });

  testWidgets('单击图片/空白收起（相册式交互）', (tester) async {
    await tester.pumpWidget(
      _host(
        onOpen: (context) =>
            showImageViewer(context, bytes: _png, title: '图'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-viewer')), findsOneWidget);

    // 点屏幕中心（图片区域）——单击关闭。
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-viewer')), findsNothing);
  });
}
