// 流式重锚态回吸原子性（2026-11-21 真机"下滑超过头部行松手被吸回头部行"
// 根因修复回归）：运行中回合让位在负向区（重锚坐标系 min=-H）时，≤48
// 回吸原实现 jumpTo(0) 按**新坐标系**取目标值却在**旧坐标系**布局上执行
// ——px=0 在重锚系=负向区顶部=运行中回合头部行在窗口底边 → 视图先被拽到
// 头部行位、rebuild 后才回贴底（用户感知"强行吸回头部行"）。
// 修复：重锚态回吸只清锚+rebuild，旧 px 越界由布局期 clamp 原子钳到新
// 贴底位（0），同一帧完成无中间态。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;
  late final sub = _Sub();

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async => null;

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: rows,
          logEpoch: 'e1',
          seq: rows.length + 1,
          firstRowId: 1,
          totalCount: rows.length,
          snapshot: {
            'title': '回吸原子性',
            'control': {'phase': 'running'},
          },
        ),
      );
    }
    return sub;
  }
}

class _Sub implements ConversationSubscription {
  @override
  final String sessionId = 's1';
  @override
  final state = ConversationState();
  @override
  bool get isDisposed => false;
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub';
  @override
  String get topic => 'conversation/s1';
  @override
  Future<void> dispose() async {}
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: 's1', title: '回吸原子性'),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _runningRows() => [
  for (var i = 0; i < 14; i++) ...[
    {'rowId': i * 3 + 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
    {'rowId': i * 3 + 2, 'kind': 'userInput', 'text': '问 $i'},
    {
      'rowId': i * 3 + 3,
      'kind': 'assistantText',
      'state': 'success',
      'text': '长会话第 $i 行 ' * 6,
    },
  ],
  // 末轮运行中（高个流式回合 ≈ 上千 px）。
  {'rowId': 43, 'kind': 'turnHeader', 'state': 'running'},
  {'rowId': 44, 'kind': 'userInput', 'text': '问 14'},
  {
    'rowId': 45,
    'kind': 'assistantText',
    'state': 'streaming',
    'text': '流式输出行内容持续增长测试 ' * 100,
  },
];

ScrollableState _scrollable(WidgetTester tester) => tester.state(
  find
      .descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void main() {
  testWidgets('重锚态回吸：清锚+clamp 原子贴底，不经过头部行中间帧', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _RowsApp(_runningRows());
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final pos = _scrollable(tester).position;

    // 1. 贴底上滑（触发结构重锚：锚点让位、运行中回合挂负向区）。
    final g1 = await tester.startGesture(const Offset(187, 400));
    for (var i = 0; i < 30; i++) {
      await g1.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      pos.minScrollExtent,
      lessThan(0),
      reason: '前置：重锚已让位（min 为负=运行中回合挂负向区）',
    );

    // 2. 向底拖到贴底邻域（dist≤48），松手 → ≤48 回吸。
    final g2 = await tester.startGesture(const Offset(187, 400));
    for (var i = 0; i < 400; i++) {
      await g2.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
      if (pos.pixels - pos.minScrollExtent <= 48) break;
    }
    expect(
      pos.pixels - pos.minScrollExtent,
      lessThanOrEqualTo(48),
      reason: '夹具：回吸窗口内松手',
    );
    final distAtRelease = pos.pixels - pos.minScrollExtent;
    await g2.up();
    // 回吸后的**第一帧**：像素做视觉等价换算（px_new=dist，两系布局对
    // 同一视差严格一致）——不经过"头部行位"（早前 jumpTo(0) 在旧坐标
    // 系执行 → 该帧 px=0=头部行位），也不瞬跳钳 0（闪感来源）。
    await tester.pump(const Duration(milliseconds: 16));
    expect(pos.minScrollExtent, 0, reason: '锚已清空（末条锚坐标系）');
    expect(
      pos.pixels,
      closeTo(distAtRelease, 1.0),
      reason: '第一帧=视觉等价位（px_new=dist），不钳 0 不跳头部行',
    );
    // 120ms 短动画平滑贴底。
    await tester.pump(const Duration(milliseconds: 200));
    expect(pos.pixels, pos.minScrollExtent, reason: '动画结束平滑贴底');
    await tester.pump(const Duration(milliseconds: 200));
    expect(pos.pixels, pos.minScrollExtent, reason: '稳定仍贴底');
  });
}
