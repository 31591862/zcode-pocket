// 助手正文自由划选复制回归（2026-11-16 用户拍板：要的是"文字可以自由
// 选中进行复制"，不是复制全文菜单）：
// ① MarkdownView 外层 SelectionArea——正文可长按/双击进入系统选择手柄+
//    复制工具条（2026-11-19 起走 SelectionArea+RenderParagraph 路径，
//    与用户气泡同款，选区盒上下留白一致）；
// ② selectable 化后长按=选择，行操作菜单在正文路径移除（协议操作承接
//    到轮尾操作行——重试按钮补进 TurnTailActions）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
          'title': '划选回归',
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
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _App extends AppState {
  late final sub = _FakeSub('s1', [
    {
      'rowId': 2,
      'kind': 'assistantText',
      'state': 'complete',
      'entityId': 'ent-1',
      'text': '这是一段需要**自由划选**的助手输出',
    },
  ]);
  int retryCalls = 0;
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    return sub;
  }

  @override
  Future<dynamic> retryTurn(
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    retryCalls++;
    return {'status': 'accepted'};
  }
}

void main() {
  testWidgets('助手正文可划选：SelectableText 在树；轮尾有重试钮', (tester) async {
    final app = _App();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: ConversationPage(sessionId: 's1', title: '划选回归'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final textFinder = find.textContaining('自由划选');
    expect(textFinder, findsOneWidget);
    // 选区路径（2026-11-19 重构）：正文固定非可选渲染包在 SelectionArea 里
    // ——选区盒由 RenderParagraph 原始度量计算，与用户气泡观感一致。
    expect(
      find.ancestor(of: textFinder, matching: find.bySubtype<SelectionArea>()),
      findsWidgets,
      reason: '正文必须在 SelectionArea 内（自由划选复制的载体）',
    );
    expect(
      find.ancestor(of: textFinder, matching: find.bySubtype<SelectableText>()),
      findsNothing,
      reason: '不再落 SelectableText（强制 strut 的选区盒上下留白不均）',
    );

    // 轮尾操作行承接协议动作：重试钮在场（长按菜单移除后不丢失）。
    final retryFinder = find.byTooltip('重试这轮');
    expect(retryFinder, findsOneWidget);
    await tester.tap(retryFinder);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.retryCalls, 1, reason: '重试钮必须触发 retryTurn');
    // 测试环境剪贴板桥——不校验系统工具条行为（平台侧）。
    addTearDown(() => Clipboard.setData(const ClipboardData(text: '')));
  });
}
