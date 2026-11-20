// 思考条行高稳定性（2026-11-20 方案 A，对齐桌面）：贴底反向列表里任何
// 高度变化都会移动整页内容——流式两行→完成一行→新段再两行的反复
// 收缩/顶起=整页弹跳（真机三代补偿方案实证均不可持续）。方案 A：
// **恒定一行**——流式与完成行高恒定，行内文字原地更新，高度永不变化。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/conversation_turn_view.dart';
import 'package:zcode_pocket/ui/motion.dart';

Map<String, dynamic> row(String state) => {
  'rowId': 1,
  'kind': 'reasoning',
  'state': state,
  'text': '第一段\n正在切换 pub.dev 源',
};

Widget host(Map<String, dynamic> r) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    body: ReasoningTile(row: r, firstSeen: DateTime.now()),
  ),
);

void main() {
  testWidgets('流式→完成行高恒定一行；预览随流式存在、完成消失', (tester) async {
    await tester.pumpWidget(host(row('streaming')));
    final streamingH = tester.getSize(find.byType(ShimmerText)).height;
    expect(
      find.textContaining('正在切换 pub.dev 源'),
      findsOneWidget,
      reason: '流式摘要=「正在思考 · 最后一行」',
    );

    // 完成边沿：行高不变（恒定一行），预览收起为短标签。
    await tester.pumpWidget(host(row('complete')));
    await tester.pump(const Duration(milliseconds: 350));
    final completedH = tester.getSize(find.byType(FixedLinesText)).height;
    expect(completedH, streamingH, reason: '恒定一行：完成不回落行高');
    expect(
      find.textContaining('正在切换 pub.dev 源'),
      findsNothing,
      reason: '完成态=「思考 · 持续了 N 秒」短标签',
    );
  });

  testWidgets('流式摘要超长截断为单行（不换行不撑高）', (tester) async {
    final long = row('streaming')..['text'] = '第一段\n${'很长的思考内容' * 20}';
    await tester.pumpWidget(host(long));
    final hLong = tester.getSize(find.byType(ShimmerText)).height;
    expect(find.textContaining('很长的思考内容'), findsOneWidget);
    await tester.pumpWidget(host(row('streaming')));
    expect(
      tester.getSize(find.byType(ShimmerText)).height,
      hLong,
      reason: '超长摘要不得撑高行盒（恒定一行）',
    );
  });
}
