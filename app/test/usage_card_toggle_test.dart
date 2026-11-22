// 用量卡开关回归（2026-11-22 用户 bug）：卡开着再点绿圈，PointerDown 先被
// 「悬浮层外点关闭」收掉、随后 tap 的 toggle 又打开——连点永远只显示不
// 关闭。修复：外点关闭按状态点矩形排除（点绿圈=开关全交 _toggleUsageCard）。
// 锁：①点绿圈开卡 ②再点绿圈关卡 ③点卡外仍关闭（外点路径不回归）。
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_composer_meta.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _FakeSub implements ConversationSubscription {
  _FakeSub(this.sessionId) {
    state.applySeed(
      ConversationSeed(
        rows: [
          {'rowId': 1, 'kind': 'turnHeader', 'state': 'completedSuccess'},
          {
            'rowId': 2,
            'kind': 'assistantText',
            'state': 'complete',
            'text': '用量卡开关回归',
          },
        ],
        logEpoch: 'e1',
        seq: 3,
        firstRowId: 1,
        totalCount: 3,
        snapshot: {
          'title': '用量卡开关',
          'control': {'phase': 'idle'},
          'usage': {
            'contextWindow': {'usedTokens': 500000, 'maxTokens': 1000000},
          },
        },
      ),
    );
  }
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get isDisposed => false;
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-$sessionId';
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

/// 空通道：开卡触发的 entitlement 拉取一律返回 null（不碰真网络）。
class _NullChannels extends ChannelClient {
  _NullChannels() : super(sendBody: (_) {});
  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async => null;
}

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
  final ChannelClient channels = _NullChannels();
  @override
  String? get workspaceKey => 'ws-usage';
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

class _UsageApp extends AppState {
  final sub = _FakeSub('s1');
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _NoopBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {'name': '测试工作区'};
  @override
  bool get conversationTransportReady => true;
  @override
  Future<ConversationSubscription> ensureConversation(
    String id, {
    Object? seedCacheEntry,
  }) async => sub;
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: const Scaffold(
      body: ConversationPage(sessionId: 's1', title: '用量卡开关'),
    ),
  ),
);

Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('绿圈开关：点开、再点关、点卡外也关', (tester) async {
    final app = _UsageApp();
    await tester.pumpWidget(_host(app));
    await _settle(tester);

    // ① 开卡。
    await tester.tap(find.byKey(const ValueKey('status-dot')));
    await _settle(tester);
    expect(
      find.byType(ContextDetailsCard),
      findsOneWidget,
      reason: '首次点绿圈必须开卡',
    );
    // 卡内压缩动作：全宽胶囊（2026-11-22 恢复——曾随排障回滚丢掉）。
    final compactBtn = tester.widget<FilledButton>(
      find.byKey(const ValueKey('compact-context')),
    );
    expect(
      compactBtn.style?.shape?.resolve({}),
      isA<StadiumBorder>(),
      reason: '压缩上下文必须是胶囊形态',
    );

    // ② 再点绿圈必须收起（修复前：down 先关、tap 又开 → 永远关不掉）。
    await tester.tap(find.byKey(const ValueKey('status-dot')));
    await _settle(tester);
    expect(
      find.byType(ContextDetailsCard),
      findsNothing,
      reason: '再点绿圈必须关掉（toggle 语义）',
    );

    // ③ 点卡外（消息区）仍关闭——外点路径不回归。点卡片左缘外 10px
    // 边距（卡 Positioned left:10；x=5 属 body 消息区背景）。
    await tester.tap(find.byKey(const ValueKey('status-dot')));
    await _settle(tester);
    expect(find.byType(ContextDetailsCard), findsOneWidget);
    final card = tester.getRect(find.byType(ContextDetailsCard));
    await tester.tapAt(Offset(5, card.center.dy));
    await _settle(tester);
    expect(
      find.byType(ContextDetailsCard),
      findsNothing,
      reason: '点卡外仍应关闭',
    );
  });
}
