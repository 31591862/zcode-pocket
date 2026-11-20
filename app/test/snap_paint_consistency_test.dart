// 贴底回吸 paint 一致性（2026-11-21 真机"尾行刚露头后再拖划不动"根因）：
// ≤48 回吸原用 correctPixels(0) 免通知改像素——锚点本就是末条时（已完成
// 会话）rebuild 不改 viewport 任何属性 → 无 relayout → paint 停在松手前
// 位置（尾行刚露头）而 pixels 已=0=贴底；再向下拖恒在 min 处无通知，
// 视觉永久冻结。修复后回吸走有通知的 jumpTo：paint 必须随 pixels 一起
// 到贴底位，后续手势不再冻结。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_message_cells.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: 's1',
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '回吸一致性',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: 's1', title: '回吸一致性'),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _longRows() => [
  for (var i = 0; i < 15; i++) ...[
    {'rowId': i * 3 + 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
    {'rowId': i * 3 + 2, 'kind': 'userInput', 'text': '问 $i'},
    {
      'rowId': i * 3 + 3,
      'kind': 'assistantText',
      'state': 'success',
      'text': '长会话第 $i 行 ' * 4,
    },
  ],
];

ScrollableState _scrollable(WidgetTester tester) => tester.state(
  find
      .descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

Rect _tailRect(WidgetTester tester) =>
    tester.getRect(find.byType(TurnTailActions).first);

void main() {
  testWidgets('≤48 回吸：paint 随 pixels 一起贴底，后续手势不冻结', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_RowsApp(_longRows())));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final pos = _scrollable(tester).position;

    // 1. 读历史（手指向下连续拖）后松手，解除贴底。
    final g1 = await tester.startGesture(const Offset(187, 400));
    for (var i = 0; i < 40; i++) {
      await g1.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      pos.pixels,
      greaterThan(pos.minScrollExtent + 48),
      reason: '前置：已离底（>48 不触发回吸）',
    );

    // 2. 连续向底拖到 dist≤40（尾行部分露出）松手 → 触发 ≤48 回吸。
    final g2 = await tester.startGesture(const Offset(187, 400));
    var distBeforeLift = 0.0;
    var tailBeforeLift = Rect.zero;
    for (var i = 0; i < 200; i++) {
      await g2.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
      final d = pos.pixels - pos.minScrollExtent;
      if (d <= 40) {
        distBeforeLift = d;
        tailBeforeLift = _tailRect(tester);
        break;
      }
    }
    expect(distBeforeLift, greaterThan(0), reason: '夹具：回吸窗口内松手');
    await g2.up();
    await tester.pump(const Duration(milliseconds: 100));

    // 回吸后 pixels 贴底；paint 必须同步移动 distBeforeLift（反向列表：
    // pixels 减小=内容上移，尾行从"露头"滑入完整可见。修复前
    // correctPixels 免通知，paint 纹丝不动=与 pixels 脱钩 distBeforeLift）。
    expect(pos.pixels, pos.minScrollExtent, reason: '回吸后应贴底');
    final tailAfterSnap = _tailRect(tester);
    expect(
      tailAfterSnap.bottom,
      closeTo(tailBeforeLift.bottom - distBeforeLift, 2.0),
      reason: '回吸后 paint 必须随 pixels 一起贴底（修复前脱钩=视觉停在露头位）',
    );

    // 3. 再向下拖：已在贴底位，pixels 恒贴底（不再"划不动"地卡在半路）。
    final g3 = await tester.startGesture(const Offset(187, 400));
    for (var i = 0; i < 8; i++) {
      await g3.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g3.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(pos.pixels, pos.minScrollExtent);
    expect(_tailRect(tester).bottom, closeTo(tailAfterSnap.bottom, 2.0),
        reason: '贴底位继续下拖视觉稳定在底部');

    // 4. 向上拖仍可离开（回吸未把手势体系锁死）。
    final g4 = await tester.startGesture(const Offset(187, 400));
    for (var i = 0; i < 12; i++) {
      await g4.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g4.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      pos.pixels,
      greaterThan(pos.minScrollExtent + 48),
      reason: '回吸后仍可正常上滑读历史',
    );
  });
}
