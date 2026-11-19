import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _AnchorSub implements ConversationSubscription {
  @override
  final String sessionId = 's-anchor';
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-anchor';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/s-anchor';
  @override
  Future<void> dispose() async {}
}

class _AnchorApp extends AppState {
  _AnchorApp(this.initialRows, this.olderRows);
  final List<Map<String, dynamic>> initialRows;
  final List<Map<String, dynamic>> olderRows;
  final sub = _AnchorSub();
  final gate = Completer<void>.sync();
  int loadOlderCalls = 0;
  int prependCount = 0;

  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: initialRows,
          logEpoch: 'e1',
          seq: initialRows.length,
          firstRowId: 1,
          totalCount: 2000,
          snapshot: const {
            'title': '历史锚点',
            'control': {'phase': 'idle'},
          },
        ),
      );
    }
    return sub;
  }

  @override
  Future<void> loadOlder(String sessionId) async {
    loadOlderCalls += 1;
    await gate.future;
    sub.state.prependOlderRows(olderRows, null, hasMore: true);
    prependCount += 1;
  }
}

List<Map<String, dynamic>> _turns({
  required int startTurn,
  required int count,
  required int firstRowId,
  required String prefix,
}) => [
  for (var i = startTurn; i < startTurn + count; i++) ...[
    {
      'rowId': firstRowId + (i - startTurn) * 3,
      'kind': 'turnHeader',
      'state': 'completedSuccess',
    },
    {
      'rowId': firstRowId + (i - startTurn) * 3 + 1,
      'kind': 'userInput',
      'text': '$prefix问 $i',
    },
    {
      'rowId': firstRowId + (i - startTurn) * 3 + 2,
      'kind': 'assistantText',
      'state': 'success',
      'text': '$prefix第 $i 行回答 ' * 8,
    },
  ],
];

ScrollableState _scrollable(WidgetTester tester) => tester.state(
  // 正文划选化后行内 EditableText 自带 Scrollable——取 .first=会话列表
  // 本体（对齐 keyboard_and_stick 适配批口径）。
  find
      .descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      )
      .first,
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('历史前插：原可见消息从提交首帧起保持原视口位置', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _AnchorApp(
      _turns(startTurn: 0, count: 14, firstRowId: 1001, prefix: ''),
      _turns(startTurn: 0, count: 8, firstRowId: 101, prefix: '更早'),
    );
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ConversationPage(sessionId: 's-anchor', title: '历史锚点'),
        ),
      ),
    );
    await _pump(tester);

    final scroll = _scrollable(tester);
    scroll.position.jumpTo(scroll.position.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('jump-bottom')), findsOneWidget);
    // 反向列表（2026-11-19）：更早历史在远端——到顶=maxScrollExtent。
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 20 && app.loadOlderCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(app.loadOlderCalls, 1, reason: '到顶应只启动一在途历史请求');
    expect(find.text('问 0'), findsOneWidget);
    final before = tester.getTopLeft(find.text('问 0')).dy;

    final observed = <double?>[];
    var observing = true;
    void frameObserver(Duration _) {
      if (!observing || app.prependCount == 0) return;
      observed.add(
        tester.any(find.text('问 0'))
            ? tester.getTopLeft(find.text('问 0')).dy
            : null,
      );
    }

    SchedulerBinding.instance.addPersistentFrameCallback(frameObserver);
    addTearDown(() => observing = false);
    app.gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));

    expect(observed, isNotEmpty, reason: '必须观察到前插后的真实绘制帧');
    // 反向列表（2026-11-19）：前插后顶距(8dp)从"问 0"上方移到新首条
    // 上方，可视位置一次性差 8dp；关键是不出现"闪走再跳回"——逐帧之间
    // 必须稳定。
    final firstFrame = observed.first;
    expect(
      firstFrame != null && observed.every((v) => v != null && (v - firstFrame).abs() <= 1.0),
      isTrue,
      reason: '前插后逐帧不得闪走再跳回；逐帧=$observed',
    );
    expect(
      firstFrame != null && (firstFrame - before).abs() <= 8.5,
      isTrue,
      reason: '前插前后位移仅限顶距重排（≤8dp）；逐帧=$observed，原位置=$before',
    );
    expect(app.prependCount, 1);
    expect(
      app.loadOlderCalls,
      1,
      reason: '前插后应按新的远端（maxScrollExtent）计算距顶距离，不得连锁自旋加载',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
