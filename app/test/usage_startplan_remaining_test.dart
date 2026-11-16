// Start Plan remaining 口径修复（2026-11-16 用户反馈"剩余额度百分比
// 不会刷新"）：桌面 buildZaiStartPlanRemaining 的 percentage 是 0-1
// **剩余比例**（桌面 quota_banner 对同字段即按剩余比例取用），用量页
// 此前误按 0-100 已用占比反转 → 0.72 显示成 99.3% 且恒定不变。
// 修复：按档分流（startPlanRemainingPercent）+ 剩余额度绝对值
// （remaining.count）上屏；个人套餐（0-100 已用占比）口径不回归。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

class _ScriptedChannel extends ChannelClient {
  _ScriptedChannel({required this.entitlement}) : super(sendBody: (_) {});

  /// getEntitlementSnapshot 的脚本载荷（按用例替换）。
  Map<String, dynamic> entitlement;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'getEntitlementSnapshot':
        return entitlement;
      case 'getCodingPlanUsageSnapshot':
        return {
          'activity': {'summary': <String, dynamic>{}},
        };
      case 'getAppUsageSnapshot':
        return {
          'summary': {'totalTokens': 100, 'activeDays': 2},
          'heatmap': <String, dynamic>{},
        };
      case 'getCodingPlanResetStatus':
      case 'requestCodingPlanResetOpportunity':
        return <String, dynamic>{};
      default:
        return <String, dynamic>{};
    }
  }
}

class _ScriptedBridge implements BridgeSession {
  _ScriptedBridge(this.scripted);
  final _ScriptedChannel scripted;
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
  ChannelClient get channels => scripted;
  @override
  String? get workspaceKey => 'ws-sp';
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
  _UsageApp() : _bridge = _ScriptedBridge(_channel);
  static final _ScriptedChannel _channel = _ScriptedChannel(
    entitlement: _startPlanEntitlement(),
  );
  final _ScriptedBridge _bridge;
  @override
  BridgeSession? get bridge => _bridge;
}

/// 桌面 getStartPlanSnapshot 的 remaining 形态（buildZaiStartPlanRemaining）：
/// count=各桶 remaining_units 合计、percentage=0-1 **剩余比例**。
Map<String, dynamic> _startPlanEntitlement({
  double percentage = 0.72,
  num count = 12000,
}) => {
  'generatedAt': DateTime.now().millisecondsSinceEpoch,
  'authenticated': true,
  'context': {'scope': 'personal'},
  'provider': {'id': 'account:bigmodel-start-plan', 'name': 'Start Plan'},
  'serverTime': DateTime.now().millisecondsSinceEpoch,
  'remaining': {
    'count': count,
    'isShow': true,
    'percentage': percentage,
    'nextResetTime': DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
  },
  'subscription': null,
  'quota': null,
};

/// 个人套餐（Coding Pro）quota 形态：percentage=0-100 已用占比、
/// usage=总额度、currentValue=已用（usage_format 既有口径）。
Map<String, dynamic> _individualEntitlement() => {
  'generatedAt': DateTime.now().millisecondsSinceEpoch,
  'authenticated': true,
  'context': {'scope': 'personal'},
  'provider': {'id': 'account:bigmodel-individual', 'name': 'GLM Coding Pro'},
  'serverTime': DateTime.now().millisecondsSinceEpoch,
  'remaining': {
    'count': 7,
    'isShow': true,
    'percentage': 30,
    'nextResetTime': DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch,
  },
  'subscription': null,
  'quota': {
    'level': 'Pro',
    'limits': [
      {
        'type': 'TOKENS_LIMIT',
        'unit': 3,
        'number': 5,
        'usage': 100,
        'currentValue': 40,
        'percentage': 40,
        'nextResetTime': DateTime.now()
            .add(const Duration(hours: 3))
            .millisecondsSinceEpoch,
      },
    ],
  },
};

void main() {
  Future<void> pumpPage(WidgetTester tester, _UsageApp app) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (call) async => 'Asia/Shanghai',
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('companion/timezone'), null));
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const UsagePage()),
      ),
    );
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Start Plan：剩余比例按 0-1 直读（0.72→72%），不误反转成 99.3%', (
    tester,
  ) async {
    final app = _UsageApp();
    await pumpPage(tester, app);

    // 默认档（个人套餐）误反转显示 99%（修复前的用户所见：恒 ~99-100%）。
    expect(find.text('99%'), findsOneWidget,
        reason: '基线：默认档下 0-1 剩余比例被误按已用反转');

    // 切到 Start Plan 档：0.72 → 72%（修复后）。
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);
    expect(find.text('72%'), findsOneWidget,
        reason: 'Start Plan percentage=0-1 剩余比例必须直读（bug：恒 ~99%）');
    expect(find.text('99%'), findsNothing);
  });

  testWidgets('Start Plan：剩余额度绝对值上屏（count=12000 → 剩余 1.2万）', (
    tester,
  ) async {
    final app = _UsageApp();
    await pumpPage(tester, app);
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);
    expect(find.textContaining('剩余 1.2万'), findsOneWidget,
        reason: '用户需求：把剩余额度数值显示出来（remaining.count）');
    // Start Plan remaining 无 usage/currentValue，不出"已用 X / Y"行。
    expect(find.textContaining('已用'), findsNothing);
  });

  testWidgets('个人套餐口径不回归：40 已用 → 60%；已用 40 / 100 行保留', (
    tester,
  ) async {
    final app = _UsageApp();
    _UsageApp._channel.entitlement = _individualEntitlement();
    addTearDown(() =>
        _UsageApp._channel.entitlement = _startPlanEntitlement());
    await pumpPage(tester, app);
    expect(find.text('60%'), findsOneWidget,
        reason: '个人套餐 percentage=0-100 已用占比，反转口径不变');
    expect(find.textContaining('已用 40 / 100'), findsOneWidget);
    // 个人套餐不出"剩余 X"行（count 语义不同，不混排）。
    expect(find.textContaining('剩余 7'), findsNothing);
  });
}
