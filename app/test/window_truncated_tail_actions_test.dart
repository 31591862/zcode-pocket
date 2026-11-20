// 窗口截断的无头末段操作行（2026-11-20 方案 A）：缓存窗口只覆盖最后一轮
// 内部（>200 行的巨型回合），turnHeader 不在窗口里 → 无头段 completedOk
// 恒 false（官方只认 complete）→ 操作行/文件卡全无，live 快照要 8-90s 才
// 到。放宽：会话非运行中 + 末轮 + 无头段有可见正文 → 按已完成渲染操作行。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_message_cells.dart';
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

TurnWork _headerlessWork() => buildChatItems([
  // 窗口起点切在回合中间：没有 turnHeader，只有工作行/正文。
  {
    'rowId': 1,
    'kind': 'toolCall',
    'toolName': 'Read',
    'status': 'success',
    'inputText': 'game.js',
  },
  {'rowId': 2, 'kind': 'assistantText', 'state': 'complete', 'text': '结论在此'},
]).whereType<TurnBarItem>().first.work;

void main() {
  testWidgets('无头末段（窗口截断）在非运行会话里显示轮尾操作行', (tester) async {
    final work = _headerlessWork();
    expect(work.header, isNull, reason: '夹具确为无头段');
    await tester.pumpWidget(
      _host(
        TurnBar(
          work: work,
          showTools: true,
          isLastTurn: true,
          firstSeenOf: (_) => null,
          toolOpen: const {},
          elapsedMsOf: (_) => null,
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
    expect(
      find.byType(TurnTailActions),
      findsOneWidget,
      reason: '方案 A：窗口截断的无头末段沿用「已完成」操作行（不等 live）',
    );
  });

  testWidgets('无头段若不是末轮则不显示操作行（中段片段保持只读）', (tester) async {
    final work = _headerlessWork();
    await tester.pumpWidget(
      _host(
        TurnBar(
          work: work,
          showTools: true,
          isLastTurn: false,
          firstSeenOf: (_) => null,
          toolOpen: const {},
          elapsedMsOf: (_) => null,
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
    expect(find.byType(TurnTailActions), findsNothing, reason: '非末轮的无头片段不挂操作行');
  });
}
