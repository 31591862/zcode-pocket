// 顶栏入口预渲期可见（2026-11-22 用户反馈）：进会话「正在同步最新消息」
// 期间 live state 未就绪，此前 actions 全部以 state != null 门控 →
// 下载/搜索/子代理/⋮ 四个入口整排消失（观感像卡死）。改 effState
// （live 回落缓存预渲）门控后，缓存预渲期入口即可用，live 到达自动切换。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _PreviewApp extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        ],
        logEpoch: 'e1',
        lastSeq: 1,
        firstRowId: 1,
        totalCount: 1,
        snapshotControl: {
          'title': '预渲会话',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  /// 订阅立即失败（等价「正在同步最新消息」区间：live state 未就绪）——
  /// 不用永挂起闸门：订阅链的 60s 超时 timer 会残留在测试收尾（pending
  /// timer 断言）。
  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async => throw UnimplementedError();
}

void main() {
  testWidgets('缓存预渲期顶栏四入口可见（同步中不再整排消失）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _PreviewApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ConversationPage(sessionId: 's1', title: '预渲会话'),
        ),
      ),
    );
    // 缓存读取（async）+ 首帧渲染。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      find.byKey(const ValueKey('cache-sync-strip')),
      findsOneWidget,
      reason: '基线：仍处于「正在同步最新消息」预渲期',
    );
    expect(
      find.byKey(const ValueKey('downloads-entry')),
      findsOneWidget,
      reason: '预渲期下载入口不得消失',
    );
    expect(
      find.byKey(const ValueKey('conversation-search-entry')),
      findsOneWidget,
      reason: '预渲期搜索入口不得消失',
    );
    expect(
      find.byKey(const ValueKey('subagents-entry')),
      findsOneWidget,
      reason: '预渲期子代理入口不得消失',
    );
    expect(
      find.byKey(const ValueKey('task-menu')),
      findsOneWidget,
      reason: '预渲期任务菜单不得消失',
    );
    expect(tester.takeException(), isNull);
  });
}
