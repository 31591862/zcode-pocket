// 思考条行高稳定性（2026-11-19 用户反馈"整页上下弹跳"）：
// 贴底反向列表里任何高度变化都会移动整页内容——「流式两行→完成回落
// 一行→新段再顶两行」的反复收缩/顶起=整页弹跳。规则：回合运行中
// 完成段保持两行定高（灰字保留末行预览），回合结束统一回落一行。
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

Widget host(Map<String, dynamic> r, {required bool turnRunning}) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(
    body: ReasoningTile(
      row: r,
      firstSeen: DateTime.now(),
      turnRunning: turnRunning,
    ),
  ),
);

void main() {
  testWidgets('运行中完成段保持两行（保留末行预览），回合结束回落一行', (tester) async {
    await tester.pumpWidget(host(row('streaming'), turnRunning: true));
    // 流式=固定两行（ShimmerText 定高公式）；tile 本体撑满 body，不可测。
    final streamingH = tester.getSize(find.byType(ShimmerText)).height;

    // 完成边沿（回合仍运行）：高度不得变化，预览保留。
    await tester.pumpWidget(host(row('complete'), turnRunning: true));
    await tester.pump(const Duration(milliseconds: 350));
    final completedH = tester.getSize(find.byType(FixedLinesText)).height;
    expect(completedH, streamingH, reason: '运行中完成段保持两行定高');
    expect(
      find.textContaining('正在切换 pub.dev 源'),
      findsOneWidget,
      reason: '保留最后一行预览（灰字无扫光）',
    );

    // 回合结束：统一回落一行。
    await tester.pumpWidget(host(row('complete'), turnRunning: false));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(FixedLinesText)).height,
      lessThan(completedH),
      reason: '回合结束才回落一行',
    );
    expect(find.textContaining('正在切换 pub.dev 源'), findsNothing);
  });

  testWidgets('历史完成轮（turnRunning=false）维持一行旧行为', (tester) async {
    await tester.pumpWidget(host(row('complete'), turnRunning: false));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.textContaining('正在切换 pub.dev 源'),
      findsNothing,
      reason: '完成轮不保留预览',
    );
  });
}
