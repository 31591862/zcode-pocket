// 末轮无头自动回填（2026-11-20 真机实证）：窗口从最后一轮内部开始
// （巨型回合 >1 页）→ turnHeader 不在窗口 → 文件卡/完成态判定缺失，
// 必须上滑触发"加载更早"才补上。live 就绪后应自动有界回填（≤2 页），
// 让"几个文件已更改"卡片无需滚动即出现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_file_summary_card.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _Sub implements ConversationSubscription {
  _Sub(this.sessionId);
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get isDisposed => false;
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub';
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _App extends AppState {
  _App({required this.initialRows, required this.olderPages});
  final List<Map<String, dynamic>> initialRows;
  final List<List<Map<String, dynamic>>> olderPages;
  late final sub = _Sub('s1');
  int loadOlderCalls = 0;
  int? lastLimit;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    if (!sub.state.ready) {
      sub.state.applySeed(
        ConversationSeed(
          rows: initialRows,
          logEpoch: 'e1',
          seq: initialRows.length + 1,
          firstRowId: 100,
          totalCount: initialRows.length,
          snapshot: const {
            'title': '回填',
            'control': {'phase': 'completedSuccess'},
          },
        ),
      );
    }
    return sub;
  }

  @override
  Future<void> loadOlder(String sessionId, {int limit = 60}) async {
    loadOlderCalls++;
    lastLimit = limit;
    if (olderPages.isEmpty) {
      sub.state.prependOlderRows(const [], null, hasMore: false);
      return;
    }
    final page = olderPages.removeAt(0);
    sub.state.prependOlderRows(page, null, hasMore: olderPages.isNotEmpty);
  }
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const ConversationPage(sessionId: 's1', title: '回填'),
  ),
);

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('窗口无 turnHeader：进会话自动回填，文件卡无需滚动即出现', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _App(
      // 初始窗口镜像真机：**首行是无头段**（其 header 在前一页），
      // 后面还有带 header 的末轮（1580）——卡片属于无头段的回合。
      initialRows: [
        {
          'rowId': 101,
          'kind': 'toolCall',
          'toolName': 'Read',
          'status': 'success',
          'inputText': 'game.js',
        },
        {
          'rowId': 102,
          'kind': 'assistantText',
          'state': 'complete',
          'text': '完成',
        },
        {
          'rowId': 1580,
          'kind': 'turnHeader',
          'state': 'completedSuccess',
          'entityId': 'e1580',
        },
        {
          'rowId': 1581,
          'kind': 'assistantText',
          'state': 'complete',
          'text': '末轮完成',
        },
      ],
      // 上一页：包含该轮的 turnHeader（带文件变更）。
      olderPages: [
        [
          {
            'rowId': 90,
            'kind': 'turnHeader',
            'state': 'completedSuccess',
            'entityId': 'e1',
            'fileChanges': {'files': 2, 'additions': 10, 'deletions': 2},
          },
          {
            'rowId': 91,
            'kind': 'toolCall',
            'toolName': 'Read',
            'status': 'success',
            'inputText': 'index.html',
          },
        ],
      ],
    );
    await tester.pumpWidget(_host(app));
    await _pump(tester);

    expect(app.loadOlderCalls, 1, reason: 'live 就绪后应自动回填一次');
    expect(app.lastLimit, 200, reason: '回填用大页请求（减少慢往返）');
    expect(
      find.byType(FileSummaryCard),
      findsWidgets,
      reason: '回填拿到 turnHeader 后文件卡应出现（无需手动上滑）',
    );
  });
}
