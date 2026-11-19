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

  /// getCodingPlanUsageSnapshot 调用计数（Start Plan 应为 0）。
  int chartCalls = 0;

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
        chartCalls++;
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
  num? total,
  Map<String, dynamic>? subscription,
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
  'subscription': subscription,
  'quota': total == null
      ? null
      : {
          'level': 'Start',
          'limits': [
            {
              'type': 'model_usage',
              'number': total,
              'usage': total - count,
              'remaining': count,
              'percentage': percentage,
            },
          ],
        },
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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        null,
      ),
    );
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

  testWidgets('Start Plan：剩余比例按 0-1 直读（0.72→72%），不误反转成 99.3%', (tester) async {
    final app = _UsageApp();
    await pumpPage(tester, app);

    // 默认档（个人套餐）误反转显示 99%（修复前的用户所见：恒 ~99-100%）。
    expect(find.text('99%'), findsOneWidget, reason: '基线：默认档下 0-1 剩余比例被误按已用反转');

    // 切到 Start Plan 档：0.72 → 72%（修复后）。
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);
    expect(
      find.text('72%'),
      findsOneWidget,
      reason: 'Start Plan percentage=0-1 剩余比例必须直读（bug：恒 ~99%）',
    );
    expect(find.text('99%'), findsNothing);
  });

  testWidgets('Start Plan：剩余额度绝对值上屏（count=12000 → 剩余 1.2万）', (tester) async {
    final app = _UsageApp();
    await pumpPage(tester, app);
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);
    // 精确数字（2026-11-16 用户需求）：count=12000 → 12,000 千分位。
    // （Start Plan 卡改桌面同款布局后，剩余数字单独成行，无「剩余」前缀。）
    expect(
      find.textContaining('12,000'),
      findsOneWidget,
      reason: '用户需求：剩余额度显示精确数字（remaining.count）',
    );
    expect(find.textContaining('1.2万'), findsNothing, reason: '不再用万/亿粗粒度格式');
    // Start Plan remaining 无 usage/currentValue，不出"已用 X / Y"行。
    expect(find.textContaining('已用'), findsNothing);
  });

  testWidgets('Start Plan 总量在场：剩余/总量 精确形态（298,341,915 / 300,000,000）', (
    tester,
  ) async {
    final app = _UsageApp();
    _UsageApp._channel.entitlement = _startPlanEntitlement(
      percentage: 0.99447305,
      count: 298341915,
      total: 300000000,
    );
    addTearDown(() => _UsageApp._channel.entitlement = _startPlanEntitlement());
    await pumpPage(tester, app);
    // 切到 Start Plan 档（默认档 individual 走旧口径，无总量行）。
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await tester.pump(const Duration(milliseconds: 2500));
    await settle(tester);

    expect(
      find.textContaining('298,341,915 / 300,000,000'),
      findsOneWidget,
      reason: '用户需求：剩余/总量 精确千分位形态',
    );
    // 桶类型 model_usage 不匹配 TOKENS_LIMIT → 仍是剩余额度单卡。
    expect(find.text('99%'), findsOneWidget, reason: '0.99447305 剩余比例 → 99%');

    // Start Plan 不打图表 RPC（monitor 聚合接口不覆盖 start-plan 档，
    // 调用必失败——跳过而非每 60s 白打一次）。
    _UsageApp._channel.chartCalls = 0;
    await tester.pump(const Duration(milliseconds: 2500));
    expect(_UsageApp._channel.chartCalls, 0, reason: 'Start Plan 档必须跳过图表拉取');
    // 误导性提示不得出现（用户报告：Start Plan 本就没有图表数据）。
    expect(find.textContaining('图表数据获取失败'), findsNothing);
  });

  testWidgets('Start Plan：过期时间上屏（details[].expireTime ISO 串 → 本地 X月X日 HH:MM）', (
    tester,
  ) async {
    final app = _UsageApp();
    _UsageApp._channel.entitlement = _startPlanEntitlement(
      subscription: {
        'identityType': 'unknown',
        'identityMasked': null,
        'details': [
          {
            'productId': 'zcode-v3-start-plan-1118',
            'productName': 'GLM 体验计划',
            // 桌面 eL(formatUnixSecondsAsIso) 输出：UTC ISO 8601 串。
            'expireTime': '2026-11-20T15:00:00.000Z',
          },
        ],
      },
    );
    addTearDown(() => _UsageApp._channel.entitlement = _startPlanEntitlement());
    await pumpPage(tester, app);
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);

    // 计划名走 details[0].productName（顶层无 plans 字段）。
    expect(find.text('GLM 体验计划'), findsOneWidget);
    final at = DateTime.parse('2026-11-20T15:00:00.000Z').toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    expect(
      find.text(
        '过期时间 ${at.month}月${at.day}日 ${two(at.hour)}:${two(at.minute)}',
      ),
      findsOneWidget,
      reason: 'expireTime 在 details[0]（ISO 串），必须解析为本地时区上屏',
    );
  });

  testWidgets('Start Plan 未生效：显示「待生效 今天 HH:mm · 过期时间 …」', (tester) async {
    final now = DateTime.now();
    final begin = now.add(const Duration(hours: 3));
    final expire = now.add(const Duration(days: 2));
    String iso(DateTime t) => t.toUtc().toIso8601String();
    // 待生效期服务端 balances 为空 → remaining 也为 null（桌面实测）。
    final pendingEnt = _startPlanEntitlement(
      subscription: {
        'identityType': 'unknown',
        'details': [
          {
            'productId': 'zcode-v3-start-plan-1118',
            'productName': 'ZCODE GLOBAL BUILD',
            // 生效时刻以权益为准（starts_at/beginTime 是领取时刻）。
            'expireTime': iso(expire),
            'entitlements': [
              {
                'entitlementId': 'ent-1',
                'showName': 'GLM-5.3-Flash',
                'effectiveTime': iso(begin),
              },
            ],
          },
        ],
      },
    );
    pendingEnt['remaining'] = null;
    _UsageApp._channel.entitlement = pendingEnt;
    addTearDown(() => _UsageApp._channel.entitlement = _startPlanEntitlement());
    final app = _UsageApp();
    await pumpPage(tester, app);
    await tester.tap(find.byKey(const ValueKey('plan-kind-start-plan')));
    await settle(tester);

    expect(find.text('ZCODE GLOBAL BUILD'), findsOneWidget);
    expect(
      find.textContaining('待生效'),
      findsWidgets,
      reason: '未生效套餐要显示生效时刻（桌面同款；占位行也含“待生效”）',
    );
    expect(find.textContaining('过期时间'), findsOneWidget);
    // 待生效期无余额桶：占位行提示生效后开始计算。
    expect(find.textContaining('生效后开始计算'), findsOneWidget);
  });

  testWidgets('个人套餐口径不回归：40 已用 → 60%；已用 40 / 100 行保留', (tester) async {
    final app = _UsageApp();
    _UsageApp._channel.entitlement = _individualEntitlement();
    addTearDown(() => _UsageApp._channel.entitlement = _startPlanEntitlement());
    await pumpPage(tester, app);
    expect(
      find.text('60%'),
      findsOneWidget,
      reason: '个人套餐 percentage=0-100 已用占比，反转口径不变',
    );
    expect(find.textContaining('已用 40 / 100'), findsOneWidget);
    // 个人套餐不出"剩余 X"行（count 语义不同，不混排）。
    expect(find.textContaining('剩余 7'), findsNothing);
  });
}
