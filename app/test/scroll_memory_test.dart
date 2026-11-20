// 滚动状态机对齐批 C 红绿（2026-10-26，官方 timelineScrollAnchor 语义）：
// ①落点裁决——非程序化窗口的滚动序列结束落点距底>48 → 解除跟随（原仅
// 手指拖拽可解除，惯性滑出被粘底 tick 拉回）；②滚动记忆——离开存位置
// 与贴底态，重进还原（非贴底不粘底）。
import 'dart:async';

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

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '滚动状态机',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

/// 两阶段红绿夹具：缓存预渲（本地读，先落地）+
/// 可控延迟的活订阅（ensureConversation 过 gate，模拟冷会话网络唤醒）。
/// 实证：此前测试环境的订阅路径从不落地（_RowsApp 无 stack 恒抛），
/// 「预渲先还原 → live ready 无条件 _stickToBottom=true+_snapToBottom
/// 跳底覆盖还原」的顺序甲竞态零覆盖——温重开阅读位置必丢。
class _PreviewLiveApp extends AppState {
  _PreviewLiveApp(this.rows, {String sessionId = 's1', this.liveSeqDelta = 0})
    : sessionId = sessionId;
  final List<Map<String, dynamic>> rows;
  final String sessionId;

  /// live 快照比缓存多的 seq 数（>0=离开期间有新输出）。
  final int liveSeqDelta;

  /// 订阅闸门：不 complete 则 ensureConversation 不返回（预渲必先落地）。
  final gate = Completer<void>();
  late final sub = _PreviewSub(sessionId);

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': '滚动状态机',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    await gate.future;
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: rows,
          logEpoch: 'e1',
          seq: rows.length + liveSeqDelta,
          firstRowId: 1,
          totalCount: rows.length,
          snapshot: const {
            'title': '滚动状态机',
            'control': {'phase': 'idle'},
          },
        ),
      );
    }
    return sub;
  }
}

class _PreviewSub implements ConversationSubscription {
  _PreviewSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-preview';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

Widget _host(AppState app, {String sessionId = 's1'}) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(sessionId: sessionId, title: '滚动状态机'),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _longRows() => [
  // 轮结构（纯正文行不进投影——buildChatItems 语义，夹具需带
  // turnHeader+userInput 成轮）。
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
  // 正文划选化后行内 EditableText 自带 Scrollable——descendant 匹配
  // 不再唯一，.single 抛 Too many elements；取 .first=会话列表本体
  //（对齐 keyboard_and_stick 适配批口径）。
  find
      .descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

void main() {
  testWidgets('落点裁决：滚动序列落点离底>48 → 解除跟随出 FAB（原仅拖拽可解）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_RowsApp(_longRows())));
    await _pump(tester);

    // 粘底态初始无 FAB。
    expect(find.byKey(const ValueKey('jump-bottom')), findsNothing);

    // 模拟"用户滚动序列结束落点离底"：直接操作 position（不经生产代码
    // 的 _markProgrammatic 窗口）→ 产生的 ScrollEnd 参与落点裁决。
    final scroll = _scrollable(tester);
    scroll.position.jumpTo(
      (scroll.position.maxScrollExtent * 0.5).clamp(0.0, double.infinity),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsOneWidget,
      reason:
          '落点距底>48 须解除跟随（对齐批 C 核心；修复前：惯性/外部'
          '滚动落点不解除，被粘底 tick 拉回）',
    );
  });

  testWidgets('进入会话一律贴底：中部离开→重进贴底（2026-11-20 对齐桌面）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _RowsApp(_longRows());

    // 第一次进入：滚到中部后退出。
    await tester.pumpWidget(_host(app));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final scroll = _scrollable(tester);
    final mid = scroll.position.maxScrollExtent * 0.5;
    scroll.position.jumpTo(mid);
    await tester.pump(const Duration(milliseconds: 100));
    // 落点裁决已解除粘底（上例语义）→ FAB 在场=非贴底态。
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold())); // 触发 dispose
    await tester.pump(const Duration(milliseconds: 100));

    // 第二次进入同会话：不做跨进入位置记忆，直接贴底。
    await tester.pumpWidget(_host(_RowsApp(_longRows())));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsNothing,
      reason: '重进贴底、无 FAB（点开会话=看最新）',
    );
    expect(
      _scrollable(tester).position.pixels,
      _scrollable(tester).position.minScrollExtent,
      reason: '像素直达贴底位，不还原中部位置',
    );
  });

  testWidgets('温重开：预渲与 live ready 均贴底（无跨进入位置还原）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _PreviewLiveApp(_longRows(), sessionId: 's-warm');
    await tester.pumpWidget(_host(app, sessionId: 's-warm'));
    app.gate.complete(); // 首进：预渲+订阅都到（防遗留订阅闸门定时器）
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    // 首进滚到中部后离开。
    final scroll = _scrollable(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump(const Duration(milliseconds: 100));

    // 温重开：预渲先落地即贴底；live ready 后仍贴底。
    final app2 = _PreviewLiveApp(_longRows(), sessionId: 's-warm');
    await tester.pumpWidget(_host(app2, sessionId: 's-warm'));
    await _pump(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsNothing,
      reason: '预渲落地即贴底，不还原中部位置',
    );
    app2.gate.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('jump-bottom')),
      findsNothing,
      reason: 'live ready 后仍贴底（两来源同语义）',
    );
    expect(
      _scrollable(tester).position.pixels,
      _scrollable(tester).position.minScrollExtent,
      reason: '像素直达贴底位',
    );
  });
}
