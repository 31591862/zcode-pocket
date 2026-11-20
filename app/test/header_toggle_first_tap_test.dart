// 头行首次点击有效性（2026-11-20 真机反馈）：折叠运行中回合 → 划到历史
// （懒列表回收，State 重建，本地 _liveCollapsed 回到初值）→ 划回 → 点
// 头行展开：首次点击必须生效。修复前点击翻转的是过期本地基线，写回的
// Map 与当前渲染态相同=视觉无变化。夹具直接构造"本地默认值 vs Map 权威
// 值不一致"的重挂后状态，一次点击即验证。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_turn_view.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

Widget _host(Widget child) => AppStateScope(
  app: AppState(),
  child: MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: child),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('重挂后首次点头行即展开（Map 权威态与本地副本不一致）', (tester) async {
    final work = buildChatItems([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
        'inputText': 'a.dart',
        'output': {'text': '内容'},
      },
      {
        'rowId': 4,
        'kind': 'assistantText',
        'state': 'streaming',
        'text': '流式正文',
      },
    ]).whereType<TurnBarItem>().first.work;

    // 重挂后状态：本地 _liveCollapsed 取默认（showTools=true → false=展开），
    // 但用户此前已折叠 → 权威 Map 里是 true（折叠）。
    final overrides = <int, bool>{work.collapseKeyId: true};

    await tester.pumpWidget(
      _host(
        TurnBar(
          work: work,
          showTools: true,
          firstSeenOf: (_) => null,
          toolOpen: const {},
          elapsedMsOf: (_) => null,
          liveCollapsedByRow: overrides,
          onLiveCollapsedChanged: (collapsed) {
            overrides[work.collapseKeyId] = collapsed;
          },
          openSession: (
            _, {
            required bool readOnly,
            required String sessionId,
            required String title,
          }) async {},
        ),
      ),
    );
    await _pump(tester);

    // 渲染态=折叠：展开时间序里的工具行不可见。
    expect(
      find.textContaining('a.dart'),
      findsNothing,
      reason: '折叠态不渲染工具行（Map 权威=折叠）',
    );

    // 第一次点击头行：必须展开（修复前此点无效）。
    await tester.tap(find.textContaining('工作中').first);
    await _pump(tester);
    expect(
      find.textContaining('a.dart'),
      findsOneWidget,
      reason: '首次点击即展开（按渲染态取反，不翻过期本地值）',
    );
  });
}
