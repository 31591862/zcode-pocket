// 工具行 display 图片（2026-11-20 对齐桌面）：mcp node_repl 截图挂在
// row.display = {kind: node_repl_images, images:[{base64,mimeType}]}——
// 此前手机端完全不消费（真机 PvZ 会话成果截图不显示）。渲染缩略图，
// 点击弹大图。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_tool_tiles.dart';
import 'package:zcode_pocket/ui/conversation_turn_view.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

// 1×1 PNG。
const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('收起态成果截图条：完成轮折叠时也显示缩略图', (tester) async {
    final work = buildChatItems([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'mcp__node_repl__js',
        'status': 'success',
        'display': {
          'kind': 'node_repl_images',
          'images': [
            {'base64': _png1x1, 'mimeType': 'image/png'},
          ],
        },
      },
      {'rowId': 4, 'kind': 'assistantText', 'state': 'complete', 'text': '完成'},
    ]).whereType<TurnBarItem>().first.work;
    expect(work.visibleTextRow, isNotNull, reason: '默认收起');
    await tester.pumpWidget(
      AppStateScope(
        app: AppState(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: TurnBar(
              work: work,
              showTools: true,
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
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('turn-display-image-0')),
      findsOneWidget,
      reason: '收起态也要露出成果截图（对齐桌面）',
    );
    expect(find.text('完成'), findsOneWidget, reason: '收起态正文仍在');
  });

  testWidgets('收起态只取最后一个带图工具行（交付截图），过程截图不汇总', (tester) async {
    final work = buildChatItems([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'mcp__node_repl__js',
        'status': 'success',
        'display': {
          'kind': 'node_repl_images',
          'images': [
            {'base64': _png1x1, 'mimeType': 'image/png'},
          ],
        },
      },
      {
        'rowId': 5,
        'kind': 'toolCall',
        'toolName': 'mcp__node_repl__js',
        'status': 'success',
        'display': {
          'kind': 'node_repl_images',
          'images': [
            {'base64': _png1x1, 'mimeType': 'image/png'},
          ],
        },
      },
      {'rowId': 6, 'kind': 'assistantText', 'state': 'complete', 'text': '完成'},
    ]).whereType<TurnBarItem>().first.work;
    await tester.pumpWidget(
      AppStateScope(
        app: AppState(),
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: TurnBar(
              work: work,
              showTools: true,
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
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('turn-display-image-0')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('turn-display-image-1')),
      findsNothing,
      reason: '只显示最后一张交付截图（过程截图不汇总到收起态）',
    );
  });

  testWidgets('工具行 display 图片：缩略图渲染、点击弹出大图对话框', (tester) async {
    final row = <String, dynamic>{
      'rowId': 1,
      'toolName': 'mcp__node_repl__js',
      'status': 'success',
      'display': {
        'kind': 'node_repl_images',
        'images': [
          {'base64': _png1x1, 'mimeType': 'image/png'},
        ],
      },
    };
    await tester.pumpWidget(_host(ToolCallTile(row: row, openByRow: {})));
    await tester.pump(const Duration(milliseconds: 100));

    final thumb = find.byKey(const ValueKey('display-image-1-0'));
    expect(thumb, findsOneWidget, reason: 'display 图片应渲染为缩略图');

    await tester.tap(thumb);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-viewer')), findsOneWidget,
        reason: '点击缩略图弹出全屏查看器');
    expect(find.byKey(const ValueKey('image-viewer-close')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('非图片 display / 无 display 不渲染缩略图', (tester) async {
    await tester.pumpWidget(
      _host(
        ToolCallTile(
          row: <String, dynamic>{
            'rowId': 2,
            'toolName': 'Read',
            'status': 'success',
            'inputText': 'a.dart',
            'display': {'kind': 'bash', 'output': 'x'},
          },
          openByRow: {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('display-image-2-0')), findsNothing);
  });
}
