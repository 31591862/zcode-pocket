// 回前台死订阅自愈回归（2026-11-16 用户报告"后台回 app 会话不刷新"）：
// 审批提醒关（默认档）退后台 90s 整栈 suspend——registry.demote dispose
// 全部会话订阅，恢复路径只重连 relay/工作区/任务索引，不补订"正开着"
// 的会话明细；页面持旧死订阅不再更新，此前只有退列表重进才恢复。
// 修复：会话页挂 app 监听，在线态发现本页订阅已 dispose 即武装有界自
// 轮询，等 bridge+activeWorkspace 就绪才重订。
// 窗口期回归（真机反馈"工作区尚未打开"横幅）：relay 在线先到、工作区
// 打开在后——重订必须等就绪，不能冲进 ensureConversation 撞
// no active workspace。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _FakeSub implements ConversationSubscription {
  _FakeSub(this.sessionId, this.rows, {this.phase = 'idle'}) {
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
        snapshot: {
          'title': '后台回前台回归',
          'control': {'phase': phase},
        },
      ),
    );
  }
  final String phase;

  final String sessionId;
  final List<Map<String, dynamic>> rows;
  @override
  final ConversationState state = ConversationState();
  bool disposed = false;
  @override
  bool get isDisposed => disposed;
  @override
  bool get hasLiveFrames => !disposed;
  @override
  String? get subscriptionId => 'sub-$sessionId';
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 最小 BridgeSession 替身（死订阅重订只判 bridge 非空，不调用其方法）。
class _NoopBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-test';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _ResubApp extends AppState {
  final _FakeSub sub1;
  _ResubApp({String sub1Phase = 'idle'}) : sub1 = _FakeSub('s1', [
    {
      'rowId': 2,
      'kind': 'assistantText',
      'state': 'complete',
      'text': '后台前的旧输出',
    },
  ], phase: sub1Phase);
  late final sub2 = _FakeSub('s1', [
    {
      'rowId': 2,
      'kind': 'assistantText',
      'state': 'complete',
      'text': '后台前的旧输出',
    },
    {
      'rowId': 3,
      'kind': 'assistantText',
      'state': 'complete',
      'text': '后台期间的新输出',
    },
  ]);
  int ensureCalls = 0;

  // 恢复链路完成后的语义：在线（90s 断连分支回前台 pokeOrResume 已落）。
  @override
  LinkPhase get phase => LinkPhase.online;

  /// 工作区就绪开关（真机反馈：relay 在线先到、工作区打开在后——
  /// bridge/activeWorkspace 未就绪时重订必须等待）。
  bool workspaceOpen = true;
  final _fakeBridge = _NoopBridge();

  @override
  BridgeSession? get bridge => workspaceOpen ? _fakeBridge : null;

  @override
  Map<String, dynamic>? get activeWorkspace =>
      workspaceOpen ? const {'name': '测试工作区'} : null;

  // 第三版修复的真正判据：会话明细传输就绪（前两版等 bridge/activeWorkspace
  // 不够——它们先于 registry._transportProvider 就位，真机复现横幅）。
  @override
  bool get conversationTransportReady => workspaceOpen;

  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async {
    ensureCalls++;
    // suspend→resume 后 registry 已重建：同 sid 返回新驻留实例。
    return sub1.disposed ? sub2 : sub1;
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: ConversationPage(sessionId: 's1', title: '回归'),
        ),
      ),
    );

Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('死订阅 + 回前台在线通知：自动重订并渲染后台期间新行', (tester) async {
    final app = _ResubApp();
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.textContaining('后台前的旧输出'), findsOneWidget,
        reason: '基线：初始订阅渲染旧内容');
    final before = app.ensureCalls;
    expect(before, greaterThanOrEqualTo(1));

    // 模拟 90s 后台断连的 suspend：整栈 demote dispose 全部会话订阅。
    app.sub1.disposed = true;
    // 模拟回前台：pokeOrResume 完成后 phase 已 online，app notifyListeners
    // （状态层 onAppResumed 末尾的通知就是页面的触发源）。
    app.notifyListeners();
    // 自轮询节拍 250ms + _subscribe 异步链。
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);

    expect(app.ensureCalls, greaterThan(before),
        reason: '死订阅必须触发重订（修复前页面持旧死订阅永不更新）');
    expect(find.textContaining('后台期间的新输出'), findsOneWidget,
        reason: '重订后新驻留实例的行（含后台期间输出）必须上屏');
  });

  testWidgets('活订阅不受影响：在线通知不触发重订', (tester) async {
    final app = _ResubApp();
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    final before = app.ensureCalls;

    // 订阅还活着（后台 <90s / 保活驻留分支）——通知不得引起重订。
    app.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    expect(app.ensureCalls, before, reason: '活订阅不重订（复核仍活）');
  });

  testWidgets('工作区未就绪：不冲订阅（不出错横幅），就绪后自轮询补订', (tester) async {
    final app = _ResubApp();
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    final before = app.ensureCalls;

    // 后台 suspend dispose 订阅；回前台时 relay 已在线但工作区还没开完。
    app.sub1.disposed = true;
    app.workspaceOpen = false;
    app.notifyListeners();
    await tester.pump(const Duration(milliseconds: 800));
    await _settle(tester, rounds: 6);
    expect(app.ensureCalls, before,
        reason: 'bridge/activeWorkspace 未就绪不得冲订阅（修复前在此窗口'
            '撞 no active workspace →"工作区尚未打开"横幅）');
    expect(find.textContaining('工作区尚未打开'), findsNothing,
        reason: '等待窗口不得给用户出错误横幅');

    // 工作区打开完成（无需新通知——自轮询不依赖通知时序）：补订接续。
    app.workspaceOpen = true;
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    expect(app.ensureCalls, greaterThan(before),
        reason: '就绪后自轮询必须补订');
    expect(find.textContaining('后台期间的新输出'), findsOneWidget);
  });

  testWidgets('活订阅僵死：运行中 60s 无状态变化 → 强制重订', (tester) async {
    // 真机 14:08 复现：订阅活着、帧流断（桌面 14:07 完成回合、手机停在
    // 14:04 运行中）——传输层看门狗的 resync RPC 若同样挂死则无人自愈。
    // 页面层兜底：运行中且 60s 无 dataVersion 变化 → dispose 旧订阅强制
    // 重订（服务端重放权威快照）。
    final app = _ResubApp(sub1Phase: 'running');
    await tester.pumpWidget(_host(app));
    await _settle(tester);
    expect(find.textContaining('后台前的旧输出'), findsOneWidget);
    final before = app.ensureCalls;

    // 帧流断（dataVersion 不再变化）+ 运行中 → app 通知武装轮询。
    app.notifyListeners();
    // 60s 僵死窗口=120 拍（假时钟推进，500ms 节拍全速跑）。
    await tester.pump(const Duration(seconds: 70));
    await _settle(tester);

    expect(app.ensureCalls, greaterThan(before),
        reason: '运行中 60s 无状态变化必须强制重订（修复前永久停在旧状态）');
    expect(find.textContaining('后台期间的新输出'), findsOneWidget,
        reason: '重订后服务端权威快照上屏');
  });
}
