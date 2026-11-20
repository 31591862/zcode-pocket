// 用户气泡左缘最小留白（2026-11-21）：删除左缘蓝竖条时曾把它的
// margin-left 56 + 竖条 3 + 间隙 6 = 65dp 约束一起丢掉 → 长文本气泡
// 在手机上左右顶满。恢复为纯 Padding(left:65)：气泡距内容区左缘
// ≥65dp（列表 16dp 内边距之外，距屏幕左缘 81dp）；大屏仍受外层
// maxWidth 520 限制（气泡最大 455dp）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/conversation_message_cells.dart';

// 150 个中文字符：足够撑满气泡宽度，又低于 180dp 折叠阈值（≈9 行）。
final _longText = '用户气泡宽度约束验证' * 15;

Widget _host(String text) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    body: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: UserBubble(text: text),
    ),
  ),
);

Future<Rect> _bubbleRect(WidgetTester tester) async {
  await tester.pumpWidget(_host(_longText));
  await tester.pump();
  final box = tester.renderObject<RenderBox>(
    find.byKey(const ValueKey('user-bubble-surface')),
  );
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  testWidgets('手机宽度：气泡左缘距屏幕 ≥81dp，不再左右顶满', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rect = await _bubbleRect(tester);
    // 屏幕 375 - 列表 16×2 = 343 内容宽；减左留白 65 = 278 气泡宽上限。
    expect(rect.right, closeTo(375 - 16, 0.5), reason: '右缘贴列表内边距');
    expect(
      rect.left,
      greaterThanOrEqualTo(16 + 65 - 0.5),
      reason: '左缘距屏幕至少 81dp（16 列表 + 65 留白）',
    );
    expect(rect.width, lessThanOrEqualTo(278 + 0.5));
  });

  testWidgets('大屏：气泡宽度不超过 455dp（外层 520 上限减 65 留白）', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rect = await _bubbleRect(tester);
    expect(rect.right, closeTo(800 - 16, 0.5));
    expect(rect.left, greaterThanOrEqualTo(800 - 16 - 455 - 0.5));
    expect(rect.width, lessThanOrEqualTo(455 + 0.5));
  });
}
