// 收起态内联正文长按回归（2026-11-16 用户反馈"输出的文字不能长按
// 触发复制"）：默认呈现=TurnBar 收起态外置正文——长按此前只挂在
// turn_view 展开态 assistantText 分支，收起态内联路径漏挂（祖先链
// 实证：正文下唯一 GestureDetector 的 onLongPress=null）。修复后
// 长按必须弹出行操作菜单（含复制入口）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _FakeSub implements ConversationSubscription {
  _FakeSub(this.sessionId, this.rows) {
    state.applySeed(
      ConversationSeed(
        rows: [
          {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          ...rows,
        ],
        logEpoch: 'e1',
        seq: rows.length + 2,
        firstRowId: 1,
        totalCount: rows.length + 2,
        snapshot: const {
          'title': '长按回归',
          'control': {'phase': 'idle'},
        },
      ),
    );
  }
  final String sessionId;
  final List<Map<String, dynamic>> rows;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get isDisposed => false;
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub';
  @override
  String get topic => 'conversation/\$sessionId';
  @override
  Future<void> dispose() async {}
}

class _App extends AppState {
  late final sub = _FakeSub('s1', [
    {
      'rowId': 2,
      'kind': 'assistantText',
      'state': 'complete',
      'text': '这是一段很长的助手输出文字用来测试长按复制',
    },
  ]);
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  Future<ConversationSubscription> ensureConversation(String id,
      {Object? seedCacheEntry}) async {
    return sub;
  }
}

void main() {
  testWidgets('收起态内联正文长按弹行操作菜单（含复制）', (tester) async {
    final app = _App();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: ConversationPage(sessionId: 's1', title: '长按回归'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final textFinder = find.textContaining('助手输出文字');
    expect(textFinder, findsOneWidget);
    // 修复判据：正文祖先链必须存在挂了 onLongPress 的 GestureDetector
    // （修复前唯一祖先的 onLongPress=null，长按落空）。
    final gestureDetectors = find
        .ancestor(of: textFinder, matching: find.byType(GestureDetector))
        .evaluate();
    final hasLongPress = gestureDetectors.any((g) =>
        (g.widget as GestureDetector).onLongPress != null);
    expect(hasLongPress, isTrue,
        reason: '收起态内联正文必须挂长按（修复前=null 长按无响应）');

    await tester.longPress(textFinder);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('复制'), findsOneWidget,
        reason: '长按必须出现行操作菜单（复制入口）');
  });
}
