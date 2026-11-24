// 图片附件缩略图（2026-11-24）：用户气泡附件行——图片 mime 显示 72×72
// 缩略图（异步字节），非图片维持回形针+文件名 chip；失败显示 broken 图标。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/attachment_thumb.dart';
import 'package:zcode_pocket/ui/conversation_message_cells.dart';

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

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
);

void main() {
  testWidgets('图片附件显示缩略图（异步字节 → Image）', (tester) async {
    await tester.pumpWidget(
      _host(
        UserBubble(
          text: '看图',
          attachments: [
            {'ref': 'r1', 'mime': 'image/png', 'fileName': 'a.png'},
          ],
          attachmentImageBytes: (i) async => _png,
        ),
      ),
    );
    expect(find.byType(AttachmentThumb), findsOneWidget);
    expect(find.byKey(const ValueKey('attachment-thumb-r1')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('非图片附件维持回形针 chip', (tester) async {
    await tester.pumpWidget(
      _host(
        UserBubble(
          text: '文件',
          attachments: [
            {'ref': 'r2', 'mime': 'application/pdf', 'fileName': 'b.pdf'},
          ],
          attachmentImageBytes: (i) async => _png,
        ),
      ),
    );
    expect(find.byType(AttachmentThumb), findsNothing);
    expect(find.byIcon(Icons.attach_file), findsOneWidget);
    expect(find.text('b.pdf'), findsOneWidget);
  });

  testWidgets('读取失败显示 broken 占位（不崩）', (tester) async {
    await tester.pumpWidget(
      _host(
        UserBubble(
          text: '看图',
          attachments: [
            {'ref': 'r3', 'mime': 'image/jpeg', 'fileName': 'c.jpg'},
          ],
          attachmentImageBytes: (i) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });
}
