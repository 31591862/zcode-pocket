// 外部订阅额度引擎 + 首页「用量速览」弹层测试：
// - Kimi Coding / OpenCode Go 适配器解析与异常结构处理
// - HTTPS-only 校验（拒绝明文 HTTP 防 API Key 泄露）
// - 缓存 TTL / force 刷新 / 错误映射（401/403/404/超时/格式错）且绝不泄露 Key
// - 首页「用量速览」弹层：官方 GLM 区 + 外部区（含桌面离线时外部区照常查询）+ 配置保存
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/external_quota.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/official_account_quota.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/usage_quick_sheet.dart';

import 'real_font_snapshot.dart';

class _UsageChannel extends ChannelClient {
  _UsageChannel(this.onCall) : super(sendBody: (_) {});
  final Future<dynamic> Function(String channel, String method, List<Object?> args)
  onCall;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) => onCall(channel, method, args);
}

class _UsageBridge implements BridgeSession {
  _UsageBridge(this.channel);
  final _UsageChannel channel;
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
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-usage';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => ConversationTransport(session: this, scope: scope);
  @override
  void dispose() {}
}

class _FakeUsageApp extends AppState {
  _FakeUsageApp({
    BridgeSession? bridge,
    UiPrefs? prefs,
    AccountStore? accountStore,
    String? activeAccountId,
    Map<String, BridgeSession>? onlineBridgesByAccount,
  }) : _bridge = bridge,
       _customPrefs = prefs,
       _activeAccountId = activeAccountId,
       _onlineBridgesByAccount = onlineBridgesByAccount ?? const {},
       super(accountStore: accountStore);

  final BridgeSession? _bridge;
  final UiPrefs? _customPrefs;
  final String? _activeAccountId;
  final Map<String, BridgeSession> _onlineBridgesByAccount;

  @override
  BridgeSession? get bridge => _bridge;

  @override
  UiPrefs get uiPrefs => _customPrefs ?? super.uiPrefs;

  @override
  String? get activeAccountId => _activeAccountId ?? super.activeAccountId;

  @override
  BridgeSession? onlineBridgeForAccount(String accountId) {
    if (_onlineBridgesByAccount.containsKey(accountId)) {
      return _onlineBridgesByAccount[accountId];
    }
    if (_activeAccountId != null && accountId == _activeAccountId) {
      return _bridge;
    }
    return super.onlineBridgeForAccount(accountId);
  }
}

void main() {
  group('ExternalQuotaAdapter & Client', () {
    test('Kimi Coding 解析 5h/7d 窗口与请求数备注', () {
      const adapter = KimiCodingQuotaAdapter();
      final now = DateTime.utc(2026, 11, 24, 6, 0);
      final snap = adapter.parseResponse({
        'usages': {
          'limit_5h': {
            'used_ratio': 0.325,
            'reset_time': '2026-11-24T10:00:00Z',
          },
          'limit_7d': {
            'used_ratio': 0.19,
            'reset_time': '2026-11-30T00:00:00Z',
          },
        },
        'limits': [
          {
            'detail': {'remaining': 42, 'limit': 100},
          },
        ],
      }, now);
      expect(snap.ok, isTrue);
      expect(snap.windows, hasLength(2));
      expect(snap.windows[0].label, '5 小时窗口');
      expect(snap.windows[0].usedPercent, 32.5);
      expect(snap.windows[0].remainingPercent, 67.5);
      expect(snap.windows[1].label, '7 天额度');
      expect(snap.windows[1].remainingPercent, 81.0);
      expect(snap.notes, ['5 小时请求数 剩余 42 / 100']);
    });

    test('OpenCode Go 解析 rolling/weekly/monthly 三窗口', () {
      const adapter = OpenCodeGoQuotaAdapter();
      final now = DateTime.utc(2026, 11, 24, 6, 0);
      final snap = adapter.parseResponse({
        'usage': {
          'rolling': {'percent': 10, 'resetsAt': '2026-11-24T09:00:00Z'},
          'weekly': {'percent': 28.4, 'resetsAt': '2026-11-29T00:00:00Z'},
          'monthly': {'percent': 15, 'resetsAt': '2026-12-01T00:00:00Z'},
        },
      }, now);
      expect(snap.ok, isTrue);
      expect(snap.windows, hasLength(3));
      expect(snap.windows[0].remainingPercent, 90.0);
      expect(snap.windows[1].remainingPercent, 71.6);
      expect(snap.windows[2].remainingPercent, 85.0);
    });

    test('resolveExternalQuotaUri：强制 HTTPS，拒绝明文 HTTP、userinfo、query/fragment 与非法 URL', () {
      const kimi = KimiCodingQuotaAdapter();
      expect(
        resolveExternalQuotaUri(kimi).toString(),
        'https://api.kimi.com/coding/v1/usages',
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'https://proxy.example/k/')
            .toString(),
        'https://proxy.example/k/v1/usages',
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'http://api.kimi.com'),
        isNull,
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'javascript:alert(1)'),
        isNull,
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'https://u:p@proxy.example'),
        isNull,
        reason: '拒绝含 userinfo 的 URL',
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'https://proxy.example?a=1'),
        isNull,
        reason: '拒绝含 query 的自定义 baseUrl',
      );
      expect(
        resolveExternalQuotaUri(kimi, customBaseUrl: 'https://proxy.example#frag'),
        isNull,
        reason: '拒绝含 fragment 的自定义 baseUrl',
      );
    });

    test('畸形数值（null/NaN/Infinity/负数）拒绝伪装成 100% 剩余', () {
      const kimi = KimiCodingQuotaAdapter();
      const ocg = OpenCodeGoQuotaAdapter();
      final now = DateTime.utc(2026, 11, 24, 6, 0);
      expect(
        () => kimi.parseResponse({
          'usages': {
            'limit_5h': {'used_ratio': null},
          },
        }, now),
        throwsFormatException,
      );
      expect(
        () => kimi.parseResponse({
          'usages': {
            'limit_5h': {'used_ratio': -0.2},
          },
        }, now),
        throwsFormatException,
      );
      expect(
        () => ocg.parseResponse({
          'usage': {
            'rolling': {'percent': double.nan},
          },
        }, now),
        throwsFormatException,
      );
      expect(
        () => ocg.parseResponse({
          'usage': {
            'rolling': {'percent': double.infinity},
          },
        }, now),
        throwsFormatException,
      );
      expect(
        () => ocg.parseResponse({
          'usage': {
            'rolling': {'percent': -5},
          },
        }, now),
        throwsFormatException,
      );
    });

    test('formatExternalResetTime：同日显 HH:mm，跨日显 MM-DD HH:mm', () {
      final now = DateTime(2026, 11, 24, 8, 0);
      final sameDay = DateTime(2026, 11, 24, 15, 5);
      final nextDay = DateTime(2026, 11, 25, 9, 30);
      expect(formatExternalResetTime(sameDay, now), '15:05');
      expect(formatExternalResetTime(nextDay, now), '11-25 09:30');
    });

    test('ExternalQuotaClient：403/404/500/超时/网络错/坏 JSON/TTL 过期/换 Key 失效', () async {
      var hits = 0;
      var now = DateTime.utc(2026, 11, 24, 6, 0);
      var mode = 'ok';
      final client = ExternalQuotaClient(
        now: () => now,
        httpGet: (uri, headers) async {
          hits++;
          switch (mode) {
            case '403':
              return (statusCode: 403, body: 'forbidden');
            case '404':
              return (statusCode: 404, body: 'not found');
            case '500':
              return (statusCode: 500, body: 'boom');
            case 'timeout':
              throw TimeoutException('timed out');
            case 'socket':
              throw const SocketException('no route');
            case 'bad_json':
              return (statusCode: 200, body: '{not-json');
            case 'empty_usages':
              return (statusCode: 200, body: '{"usages":{}}');
            default:
              return (
                statusCode: 200,
                body: jsonEncode({
                  'usages': {
                    'limit_5h': {'used_ratio': 0.2},
                  },
                }),
              );
          }
        },
      );
      const kimiCfg = ExternalQuotaProviderConfig(
        providerId: 'kimi_coding',
        apiKey: 'sk-key-a',
      );
      final okRes = await client.fetchAll({'kimi_coding': kimiCfg});
      expect(okRes.single.ok, isTrue);
      expect(hits, 1);

      // 超过 20s TTL 后缓存失效
      now = now.add(const Duration(seconds: 21));
      await client.fetchAll({'kimi_coding': kimiCfg});
      expect(hits, 2);

      // 换 key 或 baseUrl 立即失效缓存（即使在 20s 内）
      await client.fetchAll({
        'kimi_coding': const ExternalQuotaProviderConfig(
          providerId: 'kimi_coding',
          apiKey: 'sk-key-b',
        ),
      });
      expect(hits, 3);
      await client.fetchAll({
        'kimi_coding': const ExternalQuotaProviderConfig(
          providerId: 'kimi_coding',
          apiKey: 'sk-key-b',
          baseUrl: 'https://proxy.example/kimi',
        ),
      });
      expect(hits, 4);

      // 错误分支映射
      for (final pair in [
        ('403', '403'),
        ('404', '404'),
        ('500', '500'),
        ('timeout', '超时'),
        ('socket', '网络'),
        ('bad_json', '格式'),
        ('empty_usages', '格式'),
      ]) {
        mode = pair.$1;
        final res = await client.fetchAll({'kimi_coding': kimiCfg}, force: true);
        expect(res.single.ok, isFalse, reason: 'mode=${pair.$1}');
        expect(res.single.error, contains(pair.$2), reason: 'mode=${pair.$1}');
      }
    });

    test('ExternalQuotaClient：并行拉取、20s 缓存、force 刷新、401/403 不泄露 Key', () async {
      var hits = 0;
      var now = DateTime.utc(2026, 11, 24, 6, 0);
      const secretKey = 'sk-example-secret-never-leak';
      final client = ExternalQuotaClient(
        now: () => now,
        httpGet: (uri, headers) async {
          hits++;
          expect(headers['Authorization'], 'Bearer $secretKey');
          if (uri.host == 'api.kimi.com') {
            return (
              statusCode: 200,
              body: jsonEncode({
                'usages': {
                  'limit_5h': {'used_ratio': 0.2},
                },
              }),
            );
          }
          return (statusCode: 401, body: '{"error":"bad key"}');
        },
      );

      final configs = {
        'kimi_coding': const ExternalQuotaProviderConfig(
          providerId: 'kimi_coding',
          apiKey: secretKey,
        ),
        'opencode_go': const ExternalQuotaProviderConfig(
          providerId: 'opencode_go',
          apiKey: secretKey,
        ),
      };

      final first = await client.fetchAll(configs);
      expect(first, hasLength(2));
      expect(first[0].ok, isTrue);
      expect(first[0].windows.first.remainingPercent, 80.0);
      expect(first[1].ok, isFalse);
      expect(first[1].error, contains('401'));
      expect(first[1].error!.contains(secretKey), isFalse);
      expect(hits, 2);

      // 10s 内二次调用：成功的 Kimi 命中缓存，失败的 OCG 重试
      now = now.add(const Duration(seconds: 10));
      await client.fetchAll(configs);
      expect(hits, 3);

      // force=true 绕过缓存
      await client.fetchAll(configs, force: true);
      expect(hits, 5);
    });
  });

  testWidgets('用量速览弹层：官方 GLM + Kimi/OCG 外部实时展示，且桌面离线外部仍可用', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (_) async => 'Asia/Shanghai',
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        null,
      );
    });
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final extClient = ExternalQuotaClient(
      httpGet: (uri, headers) async {
        if (uri.host == 'api.kimi.com') {
          return (
            statusCode: 200,
            body: jsonEncode({
              'usages': {
                'limit_5h': {'used_ratio': 0.35},
                'limit_7d': {'used_ratio': 0.1},
              },
            }),
          );
        }
        return (
          statusCode: 200,
          body: jsonEncode({
            'usage': {
              'rolling': {'percent': 20},
              'weekly': {'percent': 40},
            },
          }),
        );
      },
    );

    final bridge = _UsageBridge(
      _UsageChannel((channel, method, args) async {
        if (method == 'getEntitlementSnapshot') {
          final acc = (args.first as Map)['accountAccess'] as Map?;
          if (acc?['mode'] == 'start-plan') {
            return {'authenticated': true, 'unavailableReason': 'no_plan'};
          }
          return {
            'status': 'ok',
            'quota': {
              'level': 'pro',
              'limits': [
                {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 58},
                {'type': 'TOKENS_LIMIT', 'unit': 6, 'number': 1, 'percentage': 22},
              ],
            },
          };
        }
        if (method == 'getCodingPlanUsageSnapshot') {
          return {
            'summary': {'totalTokens': 1240000, 'peakTokens': 418000},
          };
        }
        return null;
      }),
    );

    final app = _FakeUsageApp(bridge: bridge);
    app.uiPrefs.markMemoryReady();
    await app.uiPrefs.setExternalQuotaConfig('kimi_coding', apiKey: 'sk-test-k');
    await app.uiPrefs.setExternalQuotaConfig('opencode_go', apiKey: 'sk-test-o');

    late BuildContext ctx;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return ElevatedButton(
                  key: const ValueKey('open-quick'),
                  onPressed: () =>
                      showUsageQuickSheet(ctx, externalClient: extClient),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-quick')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('用量速览'), findsOneWidget);
    expect(find.text('GLM Coding Pro'), findsOneWidget);
    expect(find.text('剩余 42%'), findsOneWidget);
    expect(find.text('Kimi Coding'), findsOneWidget);
    expect(find.text('剩余 65%'), findsOneWidget);
    expect(find.text('OpenCode Go'), findsOneWidget);
    expect(find.text('剩余 80%'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-quick-add-external')), findsNothing);
    expect(tester.takeException(), isNull);

    // 桌面离线时：官方区降级提示，外部区照常拉取展示
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    final offlineApp = _FakeUsageApp(bridge: null);
    offlineApp.uiPrefs.markMemoryReady();
    await offlineApp.uiPrefs.setExternalQuotaConfig(
      'kimi_coding',
      apiKey: 'sk-test-k',
    );
    extClient.clearCache();
    await tester.pumpWidget(
      AppStateScope(
        app: offlineApp,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return ElevatedButton(
                  key: const ValueKey('open-quick-offline'),
                  onPressed: () =>
                      showUsageQuickSheet(ctx, externalClient: extClient),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-quick-offline')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('桌面离线'), findsOneWidget);
    expect(find.text('Kimi Coding'), findsOneWidget);
    expect(find.text('剩余 65%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认并行探测 GLM Coding + Start Plan（有福利自动显、无福利隐身）+ 右上角 + 配置 + 刷新 + EN/320dp', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (_) async => 'Asia/Shanghai',
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        null,
      );
    });
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var extHits = 0;
    final extClient = ExternalQuotaClient(
      httpGet: (uri, headers) async {
        extHits++;
        return (
          statusCode: 200,
          body: jsonEncode({
            'usages': {
              'limit_5h': {'used_ratio': 0.35},
            },
          }),
        );
      },
    );

    final entCalls = <Map<String, dynamic>>[];
    final bridge = _UsageBridge(
      _UsageChannel((channel, method, args) async {
        if (method == 'getEntitlementSnapshot') {
          final p = (args.first as Map).cast<String, dynamic>();
          final access = (p['accountAccess'] as Map).cast<String, dynamic>();
          entCalls.add(p);
          // 模拟：Coding Plan 在 bigmodel 无套餐但在 zai 有套餐，同时 Start Plan 在 bigmodel 有福利包！
          if (access['mode'] == 'start-plan' &&
              access['accountType'] == 'bigmodel') {
            return {
              'authenticated': true,
              'quota': {
                'level': 'start-plan',
                'limits': [
                  {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 18},
                ],
              },
              'mcpQuota': {
                'aggregate': {'percentage': 40},
              },
            };
          }
          if (access['mode'] == 'individual-coding-plan' &&
              access['accountType'] == 'zai') {
            return {
              'authenticated': true,
              'quota': {
                'level': 'pro',
                'limits': [
                  {
                    'type': 'TOKENS_LIMIT',
                    'unit': 3,
                    'number': 5,
                    'percentage': 40,
                  },
                ],
              },
            };
          }
          return {
            'authenticated': true,
            'unavailableReason': 'no_plan',
          };
        }
        if (method == 'getCodingPlanUsageSnapshot') {
          return {
            'summary': {'totalTokens': 1240000, 'peakTokens': 418000},
          };
        }
        return null;
      }),
    );

    final app = _FakeUsageApp(bridge: bridge);
    app.uiPrefs.markMemoryReady();

    late BuildContext ctx;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return ElevatedButton(
                  key: const ValueKey('open-quick-fallback'),
                  onPressed: () =>
                      showUsageQuickSheet(ctx, externalClient: extClient),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-quick-fallback')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 1) 主面板不再出现显眼的全宽「配置外部订阅」大按钮
    expect(find.byKey(const ValueKey('usage-quick-add-external')), findsNothing);
    // 2) Coding Plan 与激活的 Start Plan 福利包并行同时展示！
    expect(find.text('GLM Coding Pro'), findsOneWidget);
    expect(find.text('Start Plan'), findsOneWidget);
    expect(find.text('每周配额'), findsOneWidget, reason: 'unit:6 缺 number:1 仍识别为周额度');
    expect(find.text('剩余 82%'), findsOneWidget);
    expect(find.text('MCP 额度'), findsOneWidget);
    expect(find.text('剩余 60%'), findsWidgets);

    // 3) 点右上角 + 号打开「自定义用量速览」→ 初始无空白外部占位卡 → 点添加外部订阅 → 实时显示直连地址 → 明文 http:// 被拦截
    await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ext-quota-key-ext-1')), findsNothing);
    final addBtn = find.byKey(const ValueKey('ext-quota-add-entry'));
    await tester.ensureVisible(addBtn);
    await tester.tap(addBtn);
    await tester.pumpAndSettle();
    expect(
      find.text('将直连：https://api.kimi.com/coding/v1/usages（仅 GET，禁重定向）'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ext-quota-key-ext-1')),
      'sk-kimi-valid',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ext-quota-base-ext-1')),
      'http://insecure.example',
    );
    await tester.pump();
    expect(find.text('接口地址无效（仅支持 HTTPS 地址）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ext-quota-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('ext-quota-save')), findsOneWidget);

    // 4) 改为合法 HTTPS 并保存 → 弹层关闭且外部卡立刻拉取展示
    await tester.enterText(
      find.byKey(const ValueKey('ext-quota-base-ext-1')),
      'https://proxy.example/kimi',
    );
    await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('ext-quota-save')), findsNothing);
    expect(find.text('Kimi Coding'), findsOneWidget);
    expect(find.text('剩余 65%'), findsOneWidget);
    final hitsBeforeRefresh = extHits;

    // 5) 点刷新按钮强制跳过缓存重拉
    await tester.tap(find.byKey(const ValueKey('usage-quick-refresh')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(extHits, greaterThan(hitsBeforeRefresh));

    // 6) 英文 + 窄屏 320dp + 1.3 字号：检查无 'free  ' / '万' 泄漏且无缺译无溢出
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.tap(find.byKey(const ValueKey('open-quick-fallback')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('65% left'), findsOneWidget);
    expect(find.textContaining('free  '), findsNothing);
    expect(find.textContaining('万'), findsNothing);
    expect(find.textContaining('1.24M'), findsOneWidget);
    expect(L10n.missingTranslations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('UiPrefs 持久化：externalQuotas 与 projectOrder 读写/清空/损坏容错/回滚', () {
    test('externalQuotas 与 projectOrder 经 FlutterSecureStorage 往返与清空', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs1 = UiPrefs();
      await prefs1.load();
      expect(await prefs1.setExternalQuotaConfig(
        'kimi_coding',
        apiKey: 'sk-roundtrip',
        baseUrl: 'https://proxy.example/k',
      ), isTrue);
      await prefs1.setProjectOrder('dev-1', ['p-2', 'p-1']);

      final prefs2 = UiPrefs();
      await prefs2.load();
      final cfg = prefs2.externalQuotaConfig('kimi_coding');
      expect(cfg?.apiKey, 'sk-roundtrip');
      expect(cfg?.baseUrl, 'https://proxy.example/k');
      expect(prefs2.projectOrder('dev-1'), ['p-2', 'p-1']);

      // 清空后重启读取为空
      expect(await prefs2.setExternalQuotaConfig('kimi_coding', apiKey: ''), isTrue);
      await prefs2.clearProjectOrder('dev-1');
      final prefs3 = UiPrefs();
      await prefs3.load();
      expect(prefs3.hasExternalQuotas, isFalse);
      expect(prefs3.projectOrder('dev-1'), isNull);
    });

    test('externalQuotas 损坏 JSON 容错；存储写入抛错返回 false 并回滚内存', () async {
      FlutterSecureStorage.setMockInitialValues({
        'ui.externalQuotas': '{broken-json',
      });
      final prefs = UiPrefs();
      await prefs.load();
      expect(prefs.hasExternalQuotas, isFalse);

      // 注入抛错的存储实现，校验返回 false 且内存未留脏数据
      final failing = UiPrefs(storage: const _FailingSecureStorage());
      failing.markMemoryReady();
      final ok = await failing.setExternalQuotaConfig(
        'kimi_coding',
        apiKey: 'sk-should-rollback',
      );
      expect(ok, isFalse);
      expect(failing.hasExternalQuotas, isFalse);
    });

    test('v1 旧版 Map 格式自动迁移 + v2 同平台多账号持久化往返', () async {
      // 1) v1 旧版 Map 格式无缝读取
      FlutterSecureStorage.setMockInitialValues({
        'ui.externalQuotas': jsonEncode({
          'kimi_coding': {'apiKey': 'sk-legacy-kimi'},
        }),
      });
      final migrated = UiPrefs();
      await migrated.load();
      expect(migrated.externalQuotaEntries, hasLength(1));
      expect(migrated.externalQuotaConfig('kimi_coding')?.apiKey, 'sk-legacy-kimi');

      // 2) v2 同平台多账号（两个 Kimi + 一个 OCG）往返
      final ok = await migrated.replaceExternalQuotas(const [
        ExternalQuotaProviderConfig(
          id: 'kimi-1',
          providerId: 'kimi_coding',
          label: '主号',
          apiKey: 'sk-kimi-1',
        ),
        ExternalQuotaProviderConfig(
          id: 'kimi-2',
          providerId: 'kimi_coding',
          label: '备用',
          apiKey: 'sk-kimi-2',
        ),
        ExternalQuotaProviderConfig(
          id: 'ocg-1',
          providerId: 'opencode_go',
          apiKey: 'sk-ocg-1',
        ),
      ]);
      expect(ok, isTrue);

      final reloaded = UiPrefs();
      await reloaded.load();
      expect(reloaded.externalQuotaEntries, hasLength(3));
      expect(reloaded.externalQuotaEntries[0].label, '主号');
      expect(reloaded.externalQuotaEntries[1].label, '备用');
      expect(reloaded.externalQuotaEntries[1].apiKey, 'sk-kimi-2');
      expect(reloaded.externalQuotaEntries[2].providerId, 'opencode_go');
    });
  });

  testWidgets('多账号与 DIY 交互：官方 GLM 手动切区 + 无福利包自动隐身 + 外部双账号 + DIY 排序/隐藏与安全说明复制源码', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/timezone'),
      (_) async => 'Asia/Shanghai',
    );
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final extClient = ExternalQuotaClient(
      httpGet: (uri, headers) async {
        final auth = headers['Authorization'] ?? '';
        if (auth == 'Bearer sk-kimi-main') {
          return (
            statusCode: 200,
            body: jsonEncode({
              'usages': {
                'limit_5h': {'used_ratio': 0.1},
                'limit_7d': {'used_ratio': 0.2},
              },
            }),
          );
        }
        return (
          statusCode: 200,
          body: jsonEncode({
            'usages': {
              'limit_5h': {'used_ratio': 0.85},
              'limit_7d': {'used_ratio': 0.4},
            },
          }),
        );
      },
    );

    final entLog = <(String, String)>[];
    final bridge = _UsageBridge(
      _UsageChannel((channel, method, args) async {
        if (method == 'getEntitlementSnapshot') {
          final access =
              ((args.first as Map)['accountAccess'] as Map).cast<String, dynamic>();
          final fam = '${access['accountType']}';
          final mode = '${access['mode']}';
          entLog.add((fam, mode));
          if (mode == 'start-plan') {
            // 无福利包：自动模式下 Start Plan 完全隐身，不占位不报错
            return {'authenticated': true, 'unavailableReason': 'no_plan'};
          }
          if (fam == 'zai' && mode == 'individual-coding-plan') {
            return {
              'authenticated': true,
              'quota': {
                'level': 'max',
                'limits': [
                  {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 12},
                ],
              },
            };
          }
          return {
            'authenticated': true,
            'quota': {
              'level': 'pro',
              'limits': [
                {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 40},
              ],
            },
          };
        }
        return null;
      }),
    );

    final app = _FakeUsageApp(bridge: bridge);
    app.uiPrefs.markMemoryReady();

    late BuildContext ctx;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return ElevatedButton(
                  key: const ValueKey('open-multi'),
                  onPressed: () =>
                      showUsageQuickSheet(ctx, externalClient: extClient),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-multi')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('GLM Coding Pro'), findsOneWidget);
    expect(find.text('剩余 60%'), findsOneWidget);
    // Start Plan 无福利包 → 完全隐身
    expect(find.byKey(const ValueKey('usage-quick-start-card')), findsNothing);

    // 1) 点官方套餐切换胶囊 → 切到 Z.AI
    await tester.tap(find.byKey(const ValueKey('usage-quick-coding-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('usage-scope-coding-zai')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('GLM Coding Max'), findsOneWidget);
    expect(find.text('剩余 88%'), findsOneWidget);

    // 2) 点右上角 + 号打开「自定义用量速览」→ 展开安全说明并复制源码链接
    await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ext-quota-security-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ext-quota-copy-source')));
    await tester.pump();
    expect(copiedText, kExternalQuotaSourceUrl);
    expect(find.text('已复制源码链接'), findsOneWidget);
    // 收起安全说明腾出视口空间
    await tester.tap(find.byKey(const ValueKey('ext-quota-security-toggle')));
    await tester.pumpAndSettle();

    // 3) 点「添加外部订阅账号」两次 → 两个 Kimi 账号（主号/备用）
    final listScroll = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    final addBtn = find.byKey(const ValueKey('ext-quota-add-entry'));
    await tester.scrollUntilVisible(addBtn, 300, scrollable: listScroll);
    await tester.tap(addBtn);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ext-quota-label-ext-1')),
      '主号',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ext-quota-key-ext-1')),
      'sk-kimi-main',
    );

    await tester.scrollUntilVisible(addBtn, 300, scrollable: listScroll);
    await tester.tap(addBtn);
    await tester.pumpAndSettle();
    // 第二个默认选 OpenCode Go，切回 Kimi Coding 以验证同平台双账号
    final provider2 = find.byKey(const ValueKey('ext-quota-provider-ext-2'));
    await tester.scrollUntilVisible(provider2, 300, scrollable: listScroll);
    await tester.tap(provider2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kimi Coding').last);
    await tester.pumpAndSettle();
    final label2 = find.byKey(const ValueKey('ext-quota-label-ext-2'));
    await tester.scrollUntilVisible(label2, 300, scrollable: listScroll);
    await tester.enterText(label2, '备用');
    final key2 = find.byKey(const ValueKey('ext-quota-key-ext-2'));
    await tester.scrollUntilVisible(key2, 300, scrollable: listScroll);
    await tester.enterText(key2, 'sk-kimi-bak');
    await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Kimi Coding · 主号'), findsOneWidget);
    expect(find.text('剩余 90%'), findsOneWidget);
    expect(find.text('Kimi Coding · 备用'), findsOneWidget);
    expect(find.text('剩余 15%'), findsOneWidget);

    // 4) DIY 排序：把 Kimi 主号排到 GLM Coding Plan 前面 + 隐藏官方 GLM 验证跳过官方 RPC
    await app.uiPrefs.setUsageQuickLayout(
      const UsageQuickLayoutPrefs(
        order: [
          'ext:ext-1',
          kUsageCardOfficialCoding,
          kUsageCardOfficialStart,
          'ext:ext-2',
        ],
      ),
    );
    await tester.pumpAndSettle();
    final kimiY = tester.getTopLeft(find.text('Kimi Coding · 主号')).dy;
    final glmY = tester.getTopLeft(find.text('GLM Coding Pro')).dy;
    expect(kimiY, lessThan(glmY), reason: '自定义顺序生效：外部账号排在 GLM 之前');

    // 隐藏官方 Coding/Start 后刷新 → 不再请求官方 RPC，主面板只剩外部订阅
    entLog.clear();
    await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('usage-diy-toggle-official:coding')),
    );
    await tester.tap(
      find.byKey(const ValueKey('usage-diy-toggle-official:start')),
    );
    await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(entLog, isEmpty, reason: '关闭官方卡片后不再白发官方 RPC');
    expect(find.byKey(const ValueKey('usage-quick-official-card')), findsNothing);
    expect(find.text('Kimi Coding · 主号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('回归：并发竞态 / 迁移边界 / 输入校验 / 删除 / 窄屏 320dp+1.3x', () {
    test('UiPrefs 并发 replaceExternalQuotas 串行化 + delete 失败回滚 + 上限 20 + 重复/非字符串容错', () async {
      // 1) 加载时：重复 id、空 id、ext-1 碰撞、非字符串字段全部安全去重/过滤，超过 20 截断
      final rawList = <dynamic>[
        {'id': 'ext-1', 'providerId': 'kimi_coding', 'apiKey': 'sk-first'},
        {'providerId': 'kimi_coding', 'apiKey': 'sk-collide-ext1'},
        {'id': 'dup', 'providerId': 'kimi_coding', 'apiKey': 'sk-dup-1'},
        {'id': 'dup', 'providerId': 'opencode_go', 'apiKey': 'sk-dup-2'},
        {'id': '', 'providerId': 'kimi_coding', 'apiKey': 'sk-empty-id'},
        {'id': 'bad-bool', 'providerId': 'kimi_coding', 'apiKey': true},
        {'id': 'bad-num', 'providerId': 123, 'apiKey': 'sk-bad-pid'},
        for (var i = 0; i < 20; i++)
          {'id': 'extra-$i', 'providerId': 'kimi_coding', 'apiKey': 'sk-ex-$i'},
      ];
      FlutterSecureStorage.setMockInitialValues({
        'ui.externalQuotas': jsonEncode(rawList),
      });
      final loaded = UiPrefs();
      await loaded.load();
      expect(loaded.externalQuotaEntries, hasLength(kMaxExternalQuotaEntries));
      final keys = {for (final e in loaded.externalQuotaEntries) e.apiKey};
      expect(keys, containsAll(['sk-first', 'sk-collide-ext1', 'sk-dup-1', 'sk-dup-2', 'sk-empty-id']));
      expect(keys, isNot(contains('true')));
      expect(keys, isNot(contains('sk-bad-pid')));

      // 2) 超过 20 条 replaceExternalQuotas 返回 false 且不覆盖原数据
      final tooMany = [
        for (var i = 0; i < 21; i++)
          ExternalQuotaProviderConfig(
            id: 'over-$i',
            providerId: 'kimi_coding',
            apiKey: 'sk-over-$i',
          ),
      ];
      expect(await loaded.replaceExternalQuotas(tooMany), isFalse);
      expect(loaded.externalQuotaEntries, hasLength(kMaxExternalQuotaEntries));

      // 3) setExternalQuotaConfig 不传 entryId 时命中并更新/删除现有同 providerId 条目
      FlutterSecureStorage.setMockInitialValues({});
      final multi = UiPrefs();
      await multi.load();
      await multi.replaceExternalQuotas(const [
        ExternalQuotaProviderConfig(
          id: 'kimi-custom-id',
          providerId: 'kimi_coding',
          label: '主号',
          apiKey: 'sk-old',
        ),
        ExternalQuotaProviderConfig(
          id: 'ocg-custom-id',
          providerId: 'opencode_go',
          apiKey: 'sk-ocg',
        ),
      ]);
      expect(
        await multi.setExternalQuotaConfig(
          'kimi_coding',
          apiKey: 'sk-updated',
          label: '新主号',
        ),
        isTrue,
      );
      expect(multi.externalQuotaEntries, hasLength(2));
      expect(multi.externalQuotaConfig('kimi-custom-id')?.apiKey, 'sk-updated');
      expect(
        await multi.setExternalQuotaConfig('kimi_coding', apiKey: ''),
        isTrue,
      );
      expect(multi.externalQuotaEntries, hasLength(1));
      expect(multi.externalQuotaEntries.single.providerId, 'opencode_go');

      // 4) 并发 replaceExternalQuotas：Call 1 慢且写失败，Call 2 随后成功 → 串行化不互相覆写
      final ctrl = _ScriptedSecureStorage();
      final concurrent = UiPrefs(storage: ctrl);
      concurrent.markMemoryReady();
      final call1Gate = Completer<void>();
      ctrl.onWrite = (key, value) async {
        if (value != null && value.contains('sk-call-1')) {
          await call1Gate.future;
          throw PlatformException(code: 'IO_ERROR', message: 'call1 failed');
        }
      };
      final f1 = concurrent.replaceExternalQuotas(const [
        ExternalQuotaProviderConfig(
          id: 'c1',
          providerId: 'kimi_coding',
          apiKey: 'sk-call-1',
        ),
      ]);
      final f2 = concurrent.replaceExternalQuotas(const [
        ExternalQuotaProviderConfig(
          id: 'c2',
          providerId: 'kimi_coding',
          apiKey: 'sk-call-2',
        ),
      ]);
      call1Gate.complete();
      expect(await f1, isFalse);
      expect(await f2, isTrue);
      expect(concurrent.externalQuotaEntries.single.apiKey, 'sk-call-2');
      expect(ctrl.data['ui.externalQuotas'], contains('sk-call-2'));

      // 5) 清空全部（delete）抛错时返回 false 并回滚内存
      ctrl.failDelete = true;
      expect(await concurrent.replaceExternalQuotas(const []), isFalse);
      expect(concurrent.externalQuotaEntries.single.apiKey, 'sk-call-2');
    });

    test('ExternalQuotaClient：在途慢请求不复活已删账号、不覆写强刷、重复 id 去重、label 变更破缓存、换行 Key 明确报错', () async {
      // 1) 内部换行 API Key 明确返回格式错误而非「返回数据格式无法识别」
      var httpCalls = 0;
      final badKeyClient = ExternalQuotaClient(
        httpGet: (_, __) async {
          httpCalls++;
          return (statusCode: 200, body: '{}');
        },
      );
      final badKeyRes = await badKeyClient.fetchOne(
        const KimiCodingQuotaAdapter(),
        const ExternalQuotaProviderConfig(
          id: 'bad-key',
          providerId: 'kimi_coding',
          apiKey: 'sk-line1\nsk-line2',
        ),
      );
      expect(badKeyRes.ok, isFalse);
      expect(badKeyRes.error, contains('API Key 格式无效'));
      expect(httpCalls, 0);

      // 2) Kimi limits.detail 畸形/0 值过滤 + 超大 used_ratio 钳制到 100% 已用（剩余 0%）
      final kimiSnap = const KimiCodingQuotaAdapter().parseResponse({
        'usages': {
          'limit_5h': {'used_ratio': 1e308},
        },
        'limits': [
          {
            'detail': {'remaining': 42, 'limit': 0},
          },
        ],
      }, DateTime.utc(2026, 11, 24));
      expect(kimiSnap.windows.single.remainingPercent, 0.0);
      expect(kimiSnap.notes, ['5 小时请求数 剩余 42']);

      // 3) 并发竞态：慢请求在强刷之后返回不得覆盖新缓存；已删账号慢请求不得复活缓存
      final slowOld = Completer<({int statusCode, String body})>();
      var seq = 0;
      final raceClient = ExternalQuotaClient(
        httpGet: (uri, headers) async {
          seq++;
          if (seq == 1) return slowOld.future;
          return (
            statusCode: 200,
            body: jsonEncode({
              'usages': {
                'limit_5h': {'used_ratio': 0.2},
              },
            }),
          );
        },
      );
      const cfg = ExternalQuotaProviderConfig(
        id: 'k1',
        providerId: 'kimi_coding',
        label: '主号',
        apiKey: 'sk-k1',
      );
      final oldReq = raceClient.fetchAll({'k1': cfg});
      // 在旧请求完成前发起 force 刷新并迅速完成（80% 剩余）
      final fresh = await raceClient.fetchAll({'k1': cfg}, force: true);
      expect(fresh.single.windows.single.remainingPercent, 80.0);
      // 旧请求现在才返回（10% 剩余）
      slowOld.complete((
        statusCode: 200,
        body: jsonEncode({
          'usages': {
            'limit_5h': {'used_ratio': 0.9},
          },
        }),
      ));
      await oldReq;
      // 命中缓存应仍是 80%（未被旧响应覆写）
      final cached = await raceClient.fetchAll({'k1': cfg});
      expect(cached.single.windows.single.remainingPercent, 80.0);
      expect(seq, 2);

      // label 变更立即失效缓存
      final renamed = await raceClient.fetchAll({
        'k1': const ExternalQuotaProviderConfig(
          id: 'k1',
          providerId: 'kimi_coding',
          label: '改名后',
          apiKey: 'sk-k1',
        ),
      });
      expect(seq, 3);
      expect(renamed.single.accountLabel, '改名后');

      // 重复 cfg.id 自动去重，不撞缓存槽
      final dupRes = await raceClient.fetchAll({
        'slotA': const ExternalQuotaProviderConfig(
          providerId: 'kimi_coding',
          label: 'A',
          apiKey: 'sk-a',
        ),
        'slotB': const ExternalQuotaProviderConfig(
          providerId: 'kimi_coding',
          label: 'B',
          apiKey: 'sk-b',
        ),
      });
      expect(dupRes, hasLength(2));
      expect(dupRes[0].entryId, isNot(equals(dupRes[1].entryId)));
    });

    testWidgets('切官方套餐源时不卡死在途外部加载 + 刷新钮任一加载中禁用 + Z.AI Start Plan 自动回落', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        (_) async => 'Asia/Shanghai',
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          null,
        );
      });

      final extGate = Completer<({int statusCode, String body})>();
      final extClient = ExternalQuotaClient(
        httpGet: (_, __) => extGate.future,
      );
      final bridge = _UsageBridge(
        _UsageChannel((channel, method, args) async {
          if (method == 'getEntitlementSnapshot') {
            final p = args.first as Map;
            final acc = p['accountAccess'] as Map;
            // 模拟仅 zai + start-plan 有套餐，验证自动回落可直达第 4 组合
            if (acc['accountType'] == 'zai' && acc['mode'] == 'start-plan') {
              return {
                'authenticated': true,
                'quota': {'level': 'start-plan', 'limits': []},
                'remaining': {'isShow': true, 'percentage': 25},
              };
            }
            if (acc['accountType'] == 'bigmodel' &&
                acc['mode'] == 'start-plan') {
              return {'unavailableReason': 'not_authenticated'};
            }
            return {'unavailableReason': 'no_plan'};
          }
          return null;
        }),
      );
      final app = _FakeUsageApp(bridge: bridge);
      app.uiPrefs.markMemoryReady();
      await app.uiPrefs.replaceExternalQuotas(const [
        ExternalQuotaProviderConfig(
          id: 'k-slow',
          providerId: 'kimi_coding',
          label: '主号',
          apiKey: 'sk-slow',
        ),
      ]);

      late BuildContext ctx;
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  ctx = context;
                  return IconButton(
                    key: const ValueKey('open-race'),
                    onPressed: () =>
                        showUsageQuickSheet(ctx, externalClient: extClient),
                    icon: const Icon(Icons.data_usage),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open-race')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // 自动回落已命中 Z.AI Start Plan（75% 剩余），外部仍在加载中
      expect(find.text('Start Plan'), findsOneWidget);
      expect(find.text('剩余 75%'), findsOneWidget);
      expect(find.text('正在查询外部额度…'), findsOneWidget);

      // 此时官方已完成、外部仍在加载：刷新按钮必须禁用（|| 而非 &&）
      final refreshBtn = tester.widget<IconButton>(
        find.byKey(const ValueKey('usage-quick-refresh')),
      );
      expect(refreshBtn.onPressed, isNull);

      // 在外部加载仍未返回时切换 Start Plan 来源到 BigModel（返回 not_authenticated）
      // 注意：外部 CircularProgressIndicator 在转圈，不能用 pumpAndSettle（会等无限动画）
      await tester.tap(find.byKey(const ValueKey('usage-quick-start-scope')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('usage-scope-start-bigmodel')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('桌面端未登录官方账号，无法读取套餐额度'), findsOneWidget);

      // 此时放行外部响应：独立 _externalGen 确保外部卡片正常落地、不会卡死在加载转圈！
      extGate.complete((
        statusCode: 200,
        body: jsonEncode({
          'usages': {
            'limit_5h': {'used_ratio': 0.25},
          },
        }),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('正在查询外部额度…'), findsNothing);
      expect(find.text('Kimi Coding · 主号'), findsOneWidget);
      expect(find.text('剩余 75%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('UsageQuickLayoutPrefs 持久化往返 + saveUsageQuickSettings 原子回滚', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final prefs1 = UiPrefs();
      await prefs1.load();
      expect(prefs1.usageQuickLayout.isDefault, isTrue);

      final custom = const UsageQuickLayoutPrefs(
        order: ['ext:k1', kUsageCardOfficialStart, kUsageCardOfficialCoding],
        hidden: {kUsageCardOfficialCoding},
        codingScope: 'zai',
        startScope: 'bigmodel',
      );
      expect(
        await prefs1.saveUsageQuickSettings(
          externalEntries: const [
            ExternalQuotaProviderConfig(
              id: 'k1',
              providerId: 'kimi_coding',
              label: '主号',
              apiKey: 'sk-k1',
            ),
          ],
          layout: custom,
        ),
        isTrue,
      );

      final prefs2 = UiPrefs();
      await prefs2.load();
      expect(prefs2.usageQuickLayout.order, custom.order);
      expect(prefs2.usageQuickLayout.hidden, {kUsageCardOfficialCoding});
      expect(prefs2.usageQuickLayout.codingScope, 'zai');
      expect(prefs2.usageQuickLayout.startScope, 'bigmodel');
      expect(prefs2.externalQuotaEntries.single.id, 'k1');

      // 第二步写布局失败时，外部账号与布局双双回滚到旧值
      final failing = _ScriptedSecureStorage()
        ..onWrite = (key, value) async {
          if (key == 'ui.usageQuickLayout') {
            throw PlatformException(code: 'IO_ERROR', message: 'layout fail');
          }
        };
      final rollbackPrefs = UiPrefs(storage: failing);
      rollbackPrefs.markMemoryReady();
      expect(
        await rollbackPrefs.saveUsageQuickSettings(
          externalEntries: const [
            ExternalQuotaProviderConfig(
              id: 'k2',
              providerId: 'kimi_coding',
              apiKey: 'sk-k2',
            ),
          ],
          layout: custom,
        ),
        isFalse,
      );
      expect(rollbackPrefs.hasExternalQuotas, isFalse);
      expect(rollbackPrefs.usageQuickLayout.isDefault, isTrue);
      expect(failing.data['ui.externalQuotas'], isNull);
    });

    testWidgets('配置页：半填卡片拦截、20 上限提示、保存中拦截系统返回与 320dp+1.3x+EN 含 reset/长备注/安全说明零溢出', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        (_) async => 'Asia/Shanghai',
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          null,
        );
      });

      final saveGate = Completer<void>();
      final scriptedStorage = _ScriptedSecureStorage()
        ..onWrite = (key, value) async {
          if (value != null && value.contains('sk-slow-save')) {
            await saveGate.future;
          }
        };
      final extClient = ExternalQuotaClient(
        httpGet: (_, __) async => (
          statusCode: 200,
          body: jsonEncode({
            'usages': {
              'limit_5h': {
                'used_ratio': 0.325,
                'reset_time': DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 2))
                    .toIso8601String(),
              },
              'limit_7d': {
                'used_ratio': 0.125,
                'reset_time': DateTime.now()
                    .toUtc()
                    .add(const Duration(days: 4))
                    .toIso8601String(),
              },
            },
          }),
        ),
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final bridge = _UsageBridge(
        _UsageChannel((channel, method, args) async {
          if (method == 'getEntitlementSnapshot') {
            final acc = (args.first as Map)['accountAccess'] as Map;
            if (acc['mode'] == 'start-plan') {
              return {'authenticated': true, 'unavailableReason': 'no_plan'};
            }
            return {
              'authenticated': true,
              'quota': {
                'level': 'pro',
                'limits': [
                  {
                    'type': 'TOKENS_LIMIT',
                    'unit': 3,
                    'number': 5,
                    'percentage': 42,
                    'nextResetTime': nowMs + 2 * 3600 * 1000,
                  },
                  {
                    'type': 'TIME_LIMIT',
                    'percentage': 23,
                    'nextResetTime': nowMs + 25 * 86400 * 1000,
                  },
                ],
              },
            };
          }
          return null;
        }),
      );
      final app = _FakeUsageApp(bridge: bridge, prefs: UiPrefs(storage: scriptedStorage));
      app.uiPrefs.markMemoryReady();

      late BuildContext ctx;
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  ctx = context;
                  return IconButton(
                    key: const ValueKey('open-cfg-edge'),
                    onPressed: () =>
                        showUsageQuickSheet(ctx, externalClient: extClient),
                    icon: const Icon(Icons.data_usage),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-cfg-edge')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
      await tester.pumpAndSettle();

      final listScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      final addBtn = find.byKey(const ValueKey('ext-quota-add-entry'));

      // 1) 点添加后只填备注、API Key 留空 → 拦截并报错，不静默丢弃
      await tester.scrollUntilVisible(addBtn, 300, scrollable: listScroll);
      await tester.tap(addBtn);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ext-quota-label-ext-1')),
        '半填主号',
      );
      await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ext-quota-error')), findsOneWidget);
      expect(find.textContaining('API Key'), findsWidgets);

      // 删掉该条再连加到 20 条，第 21 次提示上限
      final rm1 = find.byKey(const ValueKey('ext-quota-remove-ext-1'));
      await tester.scrollUntilVisible(rm1, -300, scrollable: listScroll);
      await tester.ensureVisible(rm1);
      await tester.tap(rm1);
      await tester.pumpAndSettle();

      for (var i = 0; i < 21; i++) {
        await tester.scrollUntilVisible(addBtn, 400, scrollable: listScroll);
        await tester.tap(addBtn);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('最多可添加 20 个外部额度查询'), findsOneWidget);

      // 删掉多余条目只留第一条（ext-2），验证保存中系统返回被拦截、完成后正常回速览刷新
      for (var i = 21; i >= 3; i--) {
        final rm = find.byKey(ValueKey('ext-quota-remove-ext-$i'));
        await tester.scrollUntilVisible(rm, -400, scrollable: listScroll);
        await tester.ensureVisible(rm);
        await tester.pump();
        await tester.tap(rm);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final label1 = find.byKey(const ValueKey('ext-quota-label-ext-2'));
      await tester.scrollUntilVisible(label1, -400, scrollable: listScroll);
      await tester.ensureVisible(label1);
      await tester.enterText(
        label1,
        'VeryLongCustomAccountAliasNameForNarrowViewportOverflowCheck',
      );
      await tester.enterText(
        find.byKey(const ValueKey('ext-quota-key-ext-2')),
        'sk-slow-save',
      );
      await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
      await tester.pump();

      // 保存进行中模拟系统返回：PopScope 不应关闭配置页
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('ext-quota-save')), findsOneWidget);

      // 放行保存 → 回到速览页并拉取新账号
      saveGate.complete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('ext-quota-save')), findsNothing);
      expect(
        find.text(
          'Kimi Coding · VeryLongCustomAccountAliasNameForNarrowViewportOverflowCheck',
        ),
        findsOneWidget,
      );

      // 4) 切 EN + 320dp + 1.3x 检查速览页（含 resetTime/TIME_LIMIT/长备注）与自定义页（含展开安全说明）均零溢出零缺译
      L10n.setTestLocale('en-US');
      L10n.collectMissing = true;
      addTearDown(L10n.resetForTest);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpAndSettle();
      expect(find.text('67.5% left'), findsOneWidget);
      expect(find.text('Tool calls this month'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);

      // 打开自定义页并展开安全说明同样在 320dp + 1.3x + EN 零溢出零缺译
      await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
      await tester.pumpAndSettle();
      final secToggle = find.byKey(const ValueKey('ext-quota-security-toggle'));
      await tester.scrollUntilVisible(
        secToggle,
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(secToggle);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);
    });
  });

  group('真字体渲染采集：用量速览三服务同屏（浅/深）', () {
    setUpAll(loadRealFonts);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('渲染·用量速览紧凑网格（$tag）', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          (_) async => 'Asia/Shanghai',
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('companion/timezone'),
            null,
          );
        });
        tester.view.physicalSize = const Size(375, 806);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final extClient = ExternalQuotaClient(
          httpGet: (uri, headers) async {
            if (uri.host == 'api.kimi.com') {
              return (
                statusCode: 200,
                body: jsonEncode({
                  'usages': {
                    'limit_5h': {
                      'used_ratio': 0.0,
                      'reset_time': DateTime.now()
                          .toUtc()
                          .add(const Duration(minutes: 45))
                          .toIso8601String(),
                    },
                    'limit_7d': {
                      'used_ratio': 0.0,
                      'reset_time': DateTime.now()
                          .toUtc()
                          .add(const Duration(days: 3))
                          .toIso8601String(),
                    },
                  },
                  'limits': [
                    {
                      'detail': {'remaining': 100, 'limit': 100},
                    },
                  ],
                }),
              );
            }
            return (
              statusCode: 200,
              body: jsonEncode({
                'usage': {
                  'rolling': {
                    'percent': 0,
                    'resetsAt': DateTime.now()
                        .toUtc()
                        .add(const Duration(hours: 2))
                        .toIso8601String(),
                  },
                  'weekly': {
                    'percent': 2,
                    'resetsAt': DateTime.now()
                        .toUtc()
                        .add(const Duration(days: 5))
                        .toIso8601String(),
                  },
                  'monthly': {
                    'percent': 84,
                    'resetsAt': DateTime.now()
                        .toUtc()
                        .add(const Duration(days: 18))
                        .toIso8601String(),
                  },
                },
              }),
            );
          },
        );
        final bridge = _UsageBridge(
          _UsageChannel((channel, method, args) async {
            if (method == 'getEntitlementSnapshot') {
              final acc = (args.first as Map)['accountAccess'] as Map;
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              if (acc['mode'] == 'start-plan') {
                return {
                  'authenticated': true,
                  'quota': {'level': 'start-plan', 'limits': const <dynamic>[]},
                  'remaining': {
                    'isShow': true,
                    'percentage': 24,
                    'nextResetTime': nowMs + 12 * 86400 * 1000,
                  },
                };
              }
              return {
                'authenticated': true,
                'quota': {
                  'level': 'pro',
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': 42,
                      'nextResetTime': nowMs + 2 * 3600 * 1000,
                    },
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 6,
                      'percentage': 61,
                      'nextResetTime': nowMs + 6 * 86400 * 1000,
                    },
                    {
                      'type': 'TIME_LIMIT',
                      'percentage': 23,
                      'nextResetTime': nowMs + 25 * 86400 * 1000,
                    },
                  ],
                },
                'mcpQuota': {
                  'aggregate': {
                    'percentage': 8,
                    'nextResetTime': nowMs + 25 * 86400 * 1000,
                  },
                },
              };
            }
            if (method == 'getCodingPlanUsageSnapshot') {
              return {
                'summary': {'totalTokens': 1240000, 'peakTokens': 418000},
              };
            }
            return null;
          }),
        );
        final app = _FakeUsageApp(bridge: bridge);
        app.uiPrefs.markMemoryReady();
        await app.uiPrefs.replaceExternalQuotas(const [
          ExternalQuotaProviderConfig(
            id: 'kimi-main',
            providerId: 'kimi_coding',
            label: '主号',
            apiKey: 'sk-k1',
          ),
          ExternalQuotaProviderConfig(
            id: 'ocg-main',
            providerId: 'opencode_go',
            apiKey: 'sk-o',
          ),
        ]);

        late BuildContext ctx;
        await tester.pumpWidget(
          RepaintBoundary(
            key: realFontShotKey,
            child: AppStateScope(
              app: app,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: reviewTheme(brightness),
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      ctx = context;
                      return IconButton(
                        key: const ValueKey('open-snap'),
                        onPressed: () =>
                            showUsageQuickSheet(ctx, externalClient: extClient),
                        icon: const Icon(Icons.data_usage),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-snap')));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('GLM Coding Pro'), findsOneWidget);
        expect(find.text('Start Plan'), findsOneWidget);
        expect(find.text('Kimi Coding · 主号'), findsOneWidget);
        expect(find.text('OpenCode Go'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'usage-quick-grid-$tag-zh');

        // 同步采集 DIY 自定义页（含展开安全说明与实时直连 URL）
        await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ext-quota-security-toggle')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'usage-quick-diy-$tag-zh');
      });
    }
  });

  group('多账号多主机聚合：Start Plan 手机 JWT 直连 + Coding Plan 离线缓存', () {
    test('parseStartPlanBalanceEnvelope & OfficialStartPlanDirectClient：多桶解析/缓存/不泄露 JWT', () async {
      final now = DateTime.utc(2026, 11, 25, 2, 0);
      final expiresSec =
          now.add(const Duration(hours: 4)).millisecondsSinceEpoch ~/ 1000;
      final body = jsonEncode({
        'code': 0,
        'data': {
          'plans': [
            {
              'plan_id': 'zai-start-plan-2026',
              'name': 'Start Plan',
              'status': 'active',
            },
            {
              'plan_id': 'old-expired-plan',
              'name': 'Old Plan',
              'status': 'expired',
            },
          ],
          'balances': [
            {
              'plan_id': 'zai-start-plan-2026',
              'show_name': 'GLM-5.3-Flash',
              'total_units': 300000000,
              'used_units': 60000000,
              'remaining_units': 240000000,
              'available_units': 100000000, // 必须用 remaining_units，非 available_units
              'expires_at': expiresSec,
            },
            {
              'plan_id': 'zai-start-plan-2026',
              'show_name': 'GLM-5-Turbo',
              'total_units': 100000000,
              'used_units': 38000000,
              'remaining_units': 62000000,
              'expires_at': expiresSec,
            },
            {
              'plan_id': 'old-expired-plan',
              'show_name': 'Expired Bucket',
              'total_units': 100,
              'remaining_units': 50,
            },
          ],
        },
      });
      final parsed = parseStartPlanBalanceEnvelope(body, now: now);
      final windows = extractStartPlanWindows(parsed);
      expect(windows, hasLength(2));
      expect(windows[0].label, 'GLM-5.3-Flash');
      expect(windows[0].remainingPercent, closeTo(80.0, 0.01));
      expect(windows[1].label, 'GLM-5-Turbo');
      expect(windows[1].remainingPercent, closeTo(62.0, 0.01));

      // 无 active Start Plan → no_plan
      final noPlan = parseStartPlanBalanceEnvelope(
        jsonEncode({
          'code': 0,
          'data': {
            'plans': [
              {'plan_id': 'start-plan', 'status': 'expired'},
            ],
            'balances': const [],
          },
        }),
        now: now,
      );
      expect(noPlan['unavailableReason'], 'no_plan');
      expect(extractStartPlanWindows(noPlan), isEmpty);

      // Client 缓存、force 刷新、JWT 变更失效、401 与非法换行 JWT 拦截
      var hits = 0;
      var curNow = now;
      var status = 200;
      const secretJwt = 'header.payload.secret-jwt-token-never-leak';
      final client = OfficialStartPlanDirectClient(
        now: () => curNow,
        httpGet: (uri, headers) async {
          hits++;
          expect(uri, kOfficialStartPlanBalanceUri);
          expect(headers['Authorization'], 'Bearer $secretJwt');
          return (statusCode: status, body: body);
        },
      );
      final first = await client.fetch(accountId: 'acc-1', jwt: secretJwt);
      expect(extractStartPlanWindows(first), hasLength(2));
      expect(hits, 1);

      // 20s 内命中缓存
      await client.fetch(accountId: 'acc-1', jwt: secretJwt);
      expect(hits, 1);

      // force 强制刷新
      await client.fetch(accountId: 'acc-1', jwt: secretJwt, force: true);
      expect(hits, 2);

      // 401 返回 not_authenticated 且不泄露 JWT
      status = 401;
      final unauth = await client.fetch(
        accountId: 'acc-1',
        jwt: secretJwt,
        force: true,
      );
      expect(unauth['unavailableReason'], 'not_authenticated');
      expect(jsonEncode(unauth), isNot(contains(secretJwt)));

      // 含换行符 JWT 直接本地拒绝，不发网络请求
      final beforeHits = hits;
      final badJwt = await client.fetch(
        accountId: 'acc-1',
        jwt: 'bad\njwt',
        force: true,
      );
      expect(badJwt['unavailableReason'], 'not_authenticated');
      expect(hits, beforeHits);

      // 回归：401 强制刷新后必须驱逐 20s 内的旧缓存，不能下次非强刷吐出过期成功快照
      status = 200;
      final okAgain = await client.fetch(
        accountId: 'acc-evict',
        jwt: secretJwt,
      );
      expect(extractStartPlanWindows(okAgain), hasLength(2));
      status = 401;
      await client.fetch(accountId: 'acc-evict', jwt: secretJwt, force: true);
      final afterEvictHits = hits;
      final afterEvict = await client.fetch(
        accountId: 'acc-evict',
        jwt: secretJwt,
      );
      expect(hits, afterEvictHits + 1);
      expect(afterEvict['unavailableReason'], 'not_authenticated');

      // 回归：ends_at <= server_time 的套餐即使 status 仍为 active 也视为过期
      final expiredByTime = parseStartPlanBalanceEnvelope(
        jsonEncode({
          'code': 0,
          'data': {
            'server_time': now.millisecondsSinceEpoch ~/ 1000,
            'plans': [
              {
                'plan_id': 'zai-start-plan',
                'name': 'Start Plan',
                'status': 'active',
                'ends_at': (now.millisecondsSinceEpoch ~/ 1000) - 10,
              },
            ],
            'balances': [
              {
                'plan_id': 'zai-start-plan',
                'show_name': 'Expired Flash',
                'total_units': 100,
                'remaining_units': 100,
              },
            ],
          },
        }),
        now: now,
      );
      expect(expiredByTime['unavailableReason'], 'no_plan');
    });

    test('UiPrefs officialQuotaCache：持久化往返、10 账号上限裁剪、删除纪元防复活与缓存时长双语', () async {
      final storage = _ScriptedSecureStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();

      // 回归：在途拉取捕获旧纪元，若中途账号被删（即使当时尚无缓存），落盘不得复活
      final staleEpoch = prefs.officialQuotaCacheEpoch('acc-race');
      await prefs.removeOfficialQuotaCache('acc-race');
      await prefs.saveOfficialQuotaCache(
        const CachedOfficialQuota(
          accountId: 'acc-race',
          cachedAtMs: 1700000000000,
          family: 'bigmodel',
          planName: 'GLM Coding Pro',
          windows: [
            CachedQuotaWindow(label: '5 小时窗口', remainingPercent: 80),
          ],
        ),
        expectedEpoch: staleEpoch,
      );
      expect(prefs.officialQuotaFor('acc-race'), isNull);

      // 写入 12 个账号，应裁剪只保留最新 10 个
      for (var i = 0; i < 12; i++) {
        await prefs.saveOfficialQuotaCache(
          CachedOfficialQuota(
            accountId: 'acc-$i',
            cachedAtMs: 1700000000000 + i * 60000,
            family: i.isEven ? 'bigmodel' : 'zai',
            planName: 'GLM Coding Pro',
            windows: const [
              CachedQuotaWindow(
                label: '5 小时窗口',
                remainingPercent: 72.5,
                colorSlot: 0,
              ),
            ],
            todayTotalTokens: 500000,
          ),
        );
      }
      expect(prefs.officialQuotaCache.length, kMaxCachedOfficialQuotaAccounts);
      expect(prefs.officialQuotaFor('acc-0'), isNull);
      expect(prefs.officialQuotaFor('acc-1'), isNull);
      expect(prefs.officialQuotaFor('acc-11')?.planName, 'GLM Coding Pro');

      // 重启重载往返一致
      final reloaded = UiPrefs(storage: storage);
      await reloaded.load();
      expect(reloaded.officialQuotaCache.length, kMaxCachedOfficialQuotaAccounts);
      expect(reloaded.officialQuotaFor('acc-11')?.windows.single.remainingPercent, 72.5);

      // 删除账号联动清理缓存
      await reloaded.removeOfficialQuotaCache('acc-11');
      expect(reloaded.officialQuotaFor('acc-11'), isNull);

      // 缓存时长双语（中英文均无混杂）
      final ref = DateTime(2026, 11, 25, 12, 0);
      L10n.setTestLocale('zh-CN');
      addTearDown(L10n.resetForTest);
      expect(
        formatOfficialQuotaCacheAge(ref.subtract(const Duration(seconds: 20)), ref),
        '缓存于 刚刚',
      );
      expect(
        formatOfficialQuotaCacheAge(ref.subtract(const Duration(minutes: 15)), ref),
        '缓存于 15 分钟前',
      );
      L10n.setTestLocale('en-US');
      expect(
        formatOfficialQuotaCacheAge(ref.subtract(const Duration(minutes: 15)), ref),
        'Cached 15 min ago',
      );
      expect(
        formatOfficialQuotaCacheAge(ref.subtract(const Duration(hours: 2)), ref),
        'Cached 2 hr ago',
      );
    });

    testWidgets(
      '单账号离线：Coding Plan 显示最近缓存 + Start Plan 走手机 JWT 直连实时展示',
      (tester) async {
        final storage = _ScriptedSecureStorage();
        final accountStore = AccountStore(storage: storage);
        final accId = await accountStore.save(
          jwt: 'jwt-single-offline',
          provider: 'bigmodel',
          identity: 'single-user-1',
        );
        final prefs = UiPrefs(storage: storage);
        await prefs.load();
        await prefs.saveOfficialQuotaCache(
          CachedOfficialQuota(
            accountId: accId,
            cachedAtMs: DateTime.now()
                .subtract(const Duration(minutes: 12))
                .millisecondsSinceEpoch,
            family: 'bigmodel',
            planName: 'GLM Coding Pro',
            windows: const [
              CachedQuotaWindow(
                label: '5 小时窗口',
                remainingPercent: 64,
                colorSlot: 0,
              ),
            ],
          ),
        );

        final startClient = OfficialStartPlanDirectClient(
          httpGet: (uri, headers) async {
            expect(headers['Authorization'], 'Bearer jwt-single-offline');
            return (
              statusCode: 200,
              body: jsonEncode({
                'code': 0,
                'data': {
                  'plans': [
                    {
                      'plan_id': 'zai-start-plan',
                      'name': 'Start Plan',
                      'status': 'active',
                    },
                  ],
                  'balances': [
                    {
                      'plan_id': 'zai-start-plan',
                      'show_name': 'GLM-5.3-Flash',
                      'total_units': 300000000,
                      'used_units': 30000000,
                      'remaining_units': 270000000,
                    },
                  ],
                },
              }),
            );
          },
        );

        final app = _FakeUsageApp(
          bridge: null, // 桌面完全离线
          prefs: prefs,
          accountStore: accountStore,
          activeAccountId: accId,
        );

        late BuildContext ctx;
        await tester.pumpWidget(
          AppStateScope(
            app: app,
            child: MaterialApp(
              theme: buildAppTheme(Brightness.light),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    ctx = context;
                    return IconButton(
                      key: const ValueKey('open-single-offline'),
                      onPressed: () => showUsageQuickSheet(
                        ctx,
                        externalClient: ExternalQuotaClient(),
                        startPlanClient: startClient,
                      ),
                      icon: const Icon(Icons.data_usage),
                    );
                  },
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-single-offline')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }

        // 单账号无后缀噪音；Coding Plan 命中缓存，Start Plan 手机直连实时可见
        expect(find.text('GLM Coding Pro'), findsOneWidget);
        expect(find.textContaining('缓存于'), findsOneWidget);
        expect(find.text('剩余 64%'), findsOneWidget);
        expect(find.text('Start Plan'), findsOneWidget);
        expect(find.text('GLM-5.3-Flash'), findsOneWidget);
        expect(find.text('剩余 90%'), findsOneWidget);
        expect(find.text('直连'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '多账号多主机聚合：主号在线去重 + 备用号离线读缓存 + 备用号 Start Plan 手机直连 + DIY 隐藏 + 320dp/1.3x/EN',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          (_) async => 'Asia/Shanghai',
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('companion/timezone'),
            null,
          );
        });

        final storage = _ScriptedSecureStorage();
        final accountStore = AccountStore(storage: storage);
        final mainId = await accountStore.save(
          jwt: 'jwt-acc-main',
          provider: 'bigmodel',
          identity: 'main-uid',
        );
        await accountStore.renameAccount(mainId, '主号');
        final altId = await accountStore.save(
          jwt: 'jwt-acc-alt',
          provider: 'zai',
          identity: 'alt-uid',
        );
        await accountStore.renameAccount(altId, '备用号');

        final prefs = UiPrefs(storage: storage);
        await prefs.load();
        await prefs.saveOfficialQuotaCache(
          CachedOfficialQuota(
            accountId: altId,
            cachedAtMs: DateTime.now()
                .subtract(const Duration(minutes: 25))
                .millisecondsSinceEpoch,
            family: 'zai',
            planName: 'GLM Coding Lite',
            windows: const [
              CachedQuotaWindow(
                label: '5 小时窗口',
                remainingPercent: 88,
                colorSlot: 0,
              ),
              CachedQuotaWindow(
                label: '每周配额',
                remainingPercent: 74,
                colorSlot: 1,
              ),
            ],
          ),
        );
        await prefs.replaceExternalQuotas(const [
          ExternalQuotaProviderConfig(
            id: 'kimi-1',
            providerId: 'kimi_coding',
            apiKey: 'sk-kimi',
          ),
        ]);

        var bridgeCalls = 0;
        final mainBridge = _UsageBridge(
          _UsageChannel((channel, method, args) async {
            bridgeCalls++;
            if (method == 'getEntitlementSnapshot') {
              final acc = (args.first as Map)['accountAccess'] as Map;
              if (acc['mode'] == 'start-plan') {
                return {'authenticated': true, 'unavailableReason': 'no_plan'};
              }
              return {
                'authenticated': true,
                'quota': {
                  'level': 'pro',
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': 40,
                    },
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 6,
                      'percentage': 55,
                    },
                  ],
                },
              };
            }
            if (method == 'getCodingPlanUsageSnapshot') {
              return {
                'summary': {'totalTokens': 980000, 'peakTokens': 320000},
              };
            }
            return null;
          }),
        );

        final startDirectClient = OfficialStartPlanDirectClient(
          httpGet: (uri, headers) async {
            expect(headers['Authorization'], 'Bearer jwt-acc-alt');
            return (
              statusCode: 200,
              body: jsonEncode({
                'code': 0,
                'data': {
                  'plans': [
                    {
                      'plan_id': 'zai-start-plan',
                      'name': 'Start Plan',
                      'status': 'active',
                    },
                  ],
                  'balances': [
                    {
                      'plan_id': 'zai-start-plan',
                      'show_name': 'GLM-5.3-Flash',
                      'total_units': 300000000,
                      'used_units': 60000000,
                      'remaining_units': 240000000,
                    },
                  ],
                },
              }),
            );
          },
        );

        final extClient = ExternalQuotaClient(
          httpGet: (uri, headers) async => (
            statusCode: 200,
            body: jsonEncode({
              'usages': {
                'limit_5h': {'used_ratio': 0.1},
              },
            }),
          ),
        );

        final app = _FakeUsageApp(
          bridge: mainBridge,
          prefs: prefs,
          accountStore: accountStore,
          activeAccountId: mainId,
          onlineBridgesByAccount: {mainId: mainBridge},
        );

        late BuildContext ctx;
        await tester.pumpWidget(
          AppStateScope(
            app: app,
            child: MaterialApp(
              theme: buildAppTheme(Brightness.dark),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    ctx = context;
                    return IconButton(
                      key: const ValueKey('open-multi-acc'),
                      onPressed: () => showUsageQuickSheet(
                        ctx,
                        externalClient: extClient,
                        startPlanClient: startDirectClient,
                      ),
                      icon: const Icon(Icons.data_usage),
                    );
                  },
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-multi-acc')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }

        // 1) 主号在线拉取（且已顺手写入本地缓存）
        expect(find.text('GLM Coding Pro · 主号'), findsOneWidget);
        expect(find.text('剩余 60%'), findsOneWidget);
        expect(prefs.officialQuotaFor(mainId)?.planName, 'GLM Coding Pro');

        // 2) 主号无 Start Plan 自动隐身
        expect(find.text('Start Plan · 主号'), findsNothing);

        // 3) 备用号离线读缓存（Coding Plan）+ 手机 JWT 直连（Start Plan 福利包）
        expect(find.text('GLM Coding Lite · 备用号'), findsOneWidget);
        expect(find.text('剩余 88%'), findsOneWidget);
        expect(find.textContaining('缓存于'), findsOneWidget);
        expect(find.text('Start Plan · 备用号'), findsOneWidget);
        expect(find.text('GLM-5.3-Flash'), findsOneWidget);
        expect(find.text('剩余 80%'), findsOneWidget);
        expect(find.text('直连'), findsOneWidget);
        expect(find.text('Kimi Coding'), findsOneWidget);
        expect(bridgeCalls, greaterThan(0));

        // 4) 切 320dp + 1.3x + EN 检查零溢出零缺译
        L10n.setTestLocale('en-US');
        L10n.collectMissing = true;
        addTearDown(L10n.resetForTest);
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(find.text('Direct'), findsOneWidget);
        expect(find.textContaining('Cached '), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(L10n.missingTranslations, isEmpty);

        // 5) 打开 DIY 自定义页，单独关闭备用号 Coding Plan 并保存
        await tester.tap(find.byKey(const ValueKey('usage-quick-config')));
        await tester.pumpAndSettle();
        expect(find.text('GLM Coding Plan · 主号'), findsOneWidget);
        expect(find.text('GLM Coding Plan · 备用号'), findsOneWidget);
        expect(find.text('GLM Start Plan · 备用号'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(L10n.missingTranslations, isEmpty);

        await tester.tap(
          find.byKey(
            ValueKey('usage-diy-toggle-${usageCardOfficialCodingId(altId)}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ext-quota-save')));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }

        // 保存后备用号 Coding Plan 已隐藏，Start Plan 与主号仍正常展示
        expect(find.text('GLM Coding Lite · 备用号'), findsNothing);
        expect(find.text('GLM Coding Pro · 主号'), findsOneWidget);
        expect(find.text('Start Plan · 备用号'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('真字体渲染采集：多账号聚合（浅/深）', () {
    setUpAll(loadRealFonts);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('渲染·多账号多主机用量速览（$tag）', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          (_) async => 'Asia/Shanghai',
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('companion/timezone'),
            null,
          );
        });
        tester.view.physicalSize = const Size(375, 806);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final storage = _ScriptedSecureStorage();
        final accountStore = AccountStore(storage: storage);
        final mainId = await accountStore.save(
          jwt: 'jwt-snap-main',
          provider: 'bigmodel',
          identity: 'snap-main',
        );
        await accountStore.renameAccount(mainId, '主号');
        final altId = await accountStore.save(
          jwt: 'jwt-snap-alt',
          provider: 'zai',
          identity: 'snap-alt',
        );
        await accountStore.renameAccount(altId, '备用号');

        final prefs = UiPrefs(storage: storage);
        await prefs.load();
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        await prefs.saveOfficialQuotaCache(
          CachedOfficialQuota(
            accountId: altId,
            cachedAtMs: nowMs - 18 * 60 * 1000,
            family: 'zai',
            planName: 'GLM Coding Lite',
            windows: [
              CachedQuotaWindow(
                label: '5 小时窗口',
                remainingPercent: 88,
                resetAtMs: nowMs + 3 * 3600 * 1000,
                colorSlot: 0,
              ),
              CachedQuotaWindow(
                label: '每周配额',
                remainingPercent: 74,
                resetAtMs: nowMs + 5 * 86400 * 1000,
                colorSlot: 1,
              ),
            ],
          ),
        );
        await prefs.replaceExternalQuotas(const [
          ExternalQuotaProviderConfig(
            id: 'kimi-snap',
            providerId: 'kimi_coding',
            apiKey: 'sk-k',
          ),
        ]);

        final mainBridge = _UsageBridge(
          _UsageChannel((channel, method, args) async {
            if (method == 'getEntitlementSnapshot') {
              final acc = (args.first as Map)['accountAccess'] as Map;
              if (acc['mode'] == 'start-plan') {
                return {'authenticated': true, 'unavailableReason': 'no_plan'};
              }
              return {
                'authenticated': true,
                'quota': {
                  'level': 'pro',
                  'limits': [
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 3,
                      'number': 5,
                      'percentage': 42,
                      'nextResetTime': nowMs + 2 * 3600 * 1000,
                    },
                    {
                      'type': 'TOKENS_LIMIT',
                      'unit': 6,
                      'percentage': 61,
                      'nextResetTime': nowMs + 6 * 86400 * 1000,
                    },
                  ],
                },
              };
            }
            if (method == 'getCodingPlanUsageSnapshot') {
              return {
                'summary': {'totalTokens': 1240000, 'peakTokens': 418000},
              };
            }
            return null;
          }),
        );

        final startDirectClient = OfficialStartPlanDirectClient(
          httpGet: (uri, headers) async => (
            statusCode: 200,
            body: jsonEncode({
              'code': 0,
              'data': {
                'plans': [
                  {
                    'plan_id': 'zai-start-plan',
                    'name': 'Start Plan',
                    'status': 'active',
                  },
                ],
                'balances': [
                  {
                    'plan_id': 'zai-start-plan',
                    'show_name': 'GLM-5.3-Flash',
                    'total_units': 300000000,
                    'used_units': 54000000,
                    'remaining_units': 246000000,
                    'expires_at': (nowMs ~/ 1000) + 5 * 3600,
                  },
                  {
                    'plan_id': 'zai-start-plan',
                    'show_name': 'GLM-5-Turbo',
                    'total_units': 100000000,
                    'used_units': 38000000,
                    'remaining_units': 62000000,
                    'expires_at': (nowMs ~/ 1000) + 12 * 86400,
                  },
                ],
              },
            }),
          ),
        );

        final extClient = ExternalQuotaClient(
          httpGet: (uri, headers) async => (
            statusCode: 200,
            body: jsonEncode({
              'usages': {
                'limit_5h': {
                  'used_ratio': 0.0,
                  'reset_time': DateTime.now()
                      .toUtc()
                      .add(const Duration(minutes: 45))
                      .toIso8601String(),
                },
                'limit_7d': {
                  'used_ratio': 0.12,
                  'reset_time': DateTime.now()
                      .toUtc()
                      .add(const Duration(days: 3))
                      .toIso8601String(),
                },
              },
            }),
          ),
        );

        final app = _FakeUsageApp(
          bridge: mainBridge,
          prefs: prefs,
          accountStore: accountStore,
          activeAccountId: mainId,
          onlineBridgesByAccount: {mainId: mainBridge},
        );

        late BuildContext ctx;
        await tester.pumpWidget(
          RepaintBoundary(
            key: realFontShotKey,
            child: AppStateScope(
              app: app,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: reviewTheme(brightness),
                home: Scaffold(
                  body: Builder(
                    builder: (context) {
                      ctx = context;
                      return IconButton(
                        key: const ValueKey('open-multi-snap'),
                        onPressed: () => showUsageQuickSheet(
                          ctx,
                          externalClient: extClient,
                          startPlanClient: startDirectClient,
                        ),
                        icon: const Icon(Icons.data_usage),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-multi-snap')));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('GLM Coding Pro · 主号'), findsOneWidget);
        expect(find.text('GLM Coding Lite · 备用号'), findsOneWidget);
        expect(find.text('Start Plan · 备用号'), findsOneWidget);
        expect(find.text('Kimi Coding'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'usage-quick-multi-account-$tag-zh');
      });
    }
  });

  group('协议字段 / Start Plan 多实例过滤 / 单多账号隐藏继承回归', () {
    test('parseStartPlanBalanceEnvelope 精确按 user_plan_id 过滤过期实例并过滤过期单桶', () {
      const nowSec = 1764000000;
      final res = parseStartPlanBalanceEnvelope(
        jsonEncode({
          'data': {
            'server_time': nowSec,
            'plans': [
              {
                'user_plan_id': 'up-expired',
                'plan_id': 'zai-start-plan',
                'name': 'Start Plan',
                'status': 'active',
                'ends_at': nowSec - 60, // 已过期实例
              },
              {
                'user_plan_id': 'up-active',
                'plan_id': 'zai-start-plan',
                'name': 'Start Plan',
                'status': 'active',
                'ends_at': nowSec + 3600, // 有效实例
              },
            ],
            'balances': [
              {
                'user_plan_id': 'up-expired',
                'plan_id': 'zai-start-plan',
                'show_name': 'Expired-Old',
                'total_units': 100,
                'remaining_units': 100,
                'expires_at': nowSec + 3600,
              },
              {
                'user_plan_id': 'up-active',
                'plan_id': 'zai-start-plan',
                'show_name': 'Expired-Bucket',
                'total_units': 100,
                'remaining_units': 90,
                'expires_at': nowSec - 10, // 桶级已过期
              },
              {
                'user_plan_id': 'up-active',
                'plan_id': 'zai-start-plan',
                'show_name': 'Active-Valid',
                'total_units': 100,
                'remaining_units': 60,
                'expires_at': nowSec + 7200,
              },
            ],
          },
        }),
        now: DateTime.fromMillisecondsSinceEpoch(nowSec * 1000),
      );
      final limits = (res['quota'] as Map)['limits'] as List;
      expect(limits, hasLength(1));
      expect((limits.first as Map)['label'], 'Active-Valid');
      expect((limits.first as Map)['remainingPercent'], closeTo(60.0, 0.1));
    });

    test('UsageQuickLayoutPrefs.isOfficialCardVisible 兼容 1→2 与 2→1 隐藏态继承', () {
      const singleHidden = UsageQuickLayoutPrefs(
        hidden: {kUsageCardOfficialCoding},
      );
      expect(
        singleHidden.isOfficialCardVisible(
          usageCardOfficialCodingId('acc-1'),
          isMultiAccount: true,
        ),
        isFalse,
      );
      expect(
        singleHidden.isOfficialCardVisible(
          usageCardOfficialStartId('acc-1'),
          isMultiAccount: true,
        ),
        isTrue,
      );

      final multiHidden = UsageQuickLayoutPrefs(
        order: [
          usageCardOfficialCodingId('acc-1'),
          usageCardOfficialStartId('acc-1'),
        ],
        hidden: {usageCardOfficialCodingId('acc-1')},
      );
      expect(
        multiHidden.isOfficialCardVisible(
          kUsageCardOfficialCoding,
          isMultiAccount: false,
          singleAccountId: 'acc-1',
        ),
        isFalse,
      );
      expect(
        multiHidden.isOfficialCardVisible(
          kUsageCardOfficialStart,
          isMultiAccount: false,
          singleAccountId: 'acc-1',
        ),
        isTrue,
      );
    });

    testWidgets('真实桌面协议嵌套 activity.summary.peakDailyTokens 正确渲染今日累计与今日峰值', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/timezone'),
        (_) async => 'Asia/Shanghai',
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/timezone'),
          null,
        );
      });
      final prefs = UiPrefs(storage: _ScriptedSecureStorage());
      await prefs.load();
      final channel = _UsageChannel((ch, method, args) async {
        if (method == 'getEntitlementSnapshot') {
          final acc = (args.first as Map)['accountAccess'] as Map?;
          if (acc?['mode'] == 'start-plan') {
            return {'authenticated': true, 'unavailableReason': 'no_plan'};
          }
          return {
            'status': 'ok',
            'quota': {
              'level': 'pro',
              'limits': [
                {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 20},
              ],
            },
          };
        }
        if (method == 'getCodingPlanUsageSnapshot') {
          // 真实桌面端协议结构：summary 位于 activity 下，峰值字段名为 peakDailyTokens
          return {
            'activity': {
              'summary': {
                'totalTokens': 2340000,
                'peakDailyTokens': 876000,
              },
            },
          };
        }
        return null;
      });
      final app = _FakeUsageApp(
        prefs: prefs,
        bridge: _UsageBridge(channel),
        accountStore: AccountStore(storage: _ScriptedSecureStorage()),
      );

      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  key: const ValueKey('open-nested-summary'),
                  onPressed: () => showUsageQuickSheet(
                    ctx,
                    externalClient: ExternalQuotaClient(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-nested-summary')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('234万'), findsOneWidget);
      expect(find.textContaining('87.6万'), findsOneWidget);
    });
  });
}

class _FailingSecureStorage extends FlutterSecureStorage {
  const _FailingSecureStorage()
    : super(
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw PlatformException(code: 'IO_ERROR', message: 'disk full');
  }
}

class _ScriptedSecureStorage extends FlutterSecureStorage {
  _ScriptedSecureStorage()
    : super(
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  final Map<String, String> data = {};
  Future<void> Function(String key, String? value)? onWrite;
  bool failDelete = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (onWrite != null) {
      await onWrite!(key, value);
    }
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDelete) {
      throw PlatformException(code: 'IO_ERROR', message: 'delete failed');
    }
    data.remove(key);
  }
}
