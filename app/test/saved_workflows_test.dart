// 已保存工作流一键启动测试：解析 / 实参校验 / 拒绝码人话映射 /
// 列表加载 / 无参直启 / 有参表单提交 / 启动被拒回收空会话 / 旧 CLI 不支持态。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/saved_workflows_page.dart';

import 'real_font_snapshot.dart';

class _SavedWfChannel extends ChannelClient {
  _SavedWfChannel(this.onCall) : super(sendBody: (_) {});

  final Future<dynamic> Function(
    String channel,
    String method,
    List<Object?> args,
  ) onCall;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) => onCall(channel, method, args);
}

class _SavedWfBridge implements BridgeSession {
  _SavedWfBridge(
    this.channel, {
    this.projectIntent,
  });
  final _SavedWfChannel channel;
  @override
  final Map<String, dynamic>? projectIntent;
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
  String? get workspaceKey => 'ws-wf';
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

class _MemProfiles extends ProfileStore {
  _MemProfiles(this.items);
  List<DeviceProfile> items;
  @override
  Future<({List<DeviceProfile> profiles, int skipped})>
  listProfilesDetailed() async => (profiles: List.of(items), skipped: 0);
  @override
  Future<DeviceProfile> upsertProfile(DeviceProfile p) async => p;
  @override
  Future<void> updateProfile(DeviceProfile p) async {}
  @override
  Future<void> removeProfile(String sid) async {}
  @override
  Future<void> setActiveDeviceSid(String? sid) async {}
}

class _WfProbeStack extends ComputerStack {
  _WfProbeStack(
    DeviceProfile profile, {
    required BridgeSession bridge,
    required ConversationTransport conv,
    required Map<String, dynamic> workspace,
    List<Map<String, dynamic>> seedProjects = const [],
  }) : _probeBridge = bridge,
       super(profile: profile, onLog: (_) {}, onFailure: (_, _) {}) {
    activeWorkspace = workspace;
    projects = seedProjects;
    debugSeedConversationTransportForTest(conv);
  }

  final BridgeSession _probeBridge;
  int reloadCalls = 0;

  @override
  BridgeSession? get bridge => _probeBridge;

  @override
  Future<void> start() async {}

  @override
  Future<void> pokeOrResume() async {}

  @override
  void reloadTaskIndex() {
    reloadCalls++;
  }
}

class _FakeSavedWfApp extends AppState {
  _FakeSavedWfApp({
    this.projectResult,
    this.globalResult,
    this.listError,
    this.globalError,
    this.onLaunch,
  });

  final dynamic projectResult;
  final dynamic globalResult;
  final Object? listError;
  final Object? globalError;
  final Future<
    ({
      bool ok,
      String? sessionId,
      String? runId,
      String? errorCode,
      String? errorMessage,
    })
  >
  Function({
    required String name,
    required String scope,
    required Map<String, dynamic> args,
  })?
  onLaunch;

  final List<({String name, String scope, Map<String, dynamic> args})>
  launches = [];

  @override
  Future<dynamic> listSavedWorkflows({String scope = 'project'}) async {
    if (listError != null) throw listError!;
    if (scope == 'global' && globalError != null) throw globalError!;
    return scope == 'project' ? projectResult : globalResult;
  }

  @override
  Future<
    ({
      bool ok,
      String? sessionId,
      String? runId,
      String? errorCode,
      String? errorMessage,
    })
  >
  launchSavedWorkflow({
    required String name,
    required String scope,
    Map<String, dynamic> args = const {},
  }) async {
    launches.add((name: name, scope: scope, args: args));
    if (onLaunch != null) {
      return onLaunch!(name: name, scope: scope, args: args);
    }
    return (
      ok: true,
      sessionId: 'sess-new-1',
      runId: 'run-new-1',
      errorCode: null,
      errorMessage: null,
    );
  }
}

Widget _host(AppState app, Widget child) => AppStateScope(
  app: app,
  child: MaterialApp(theme: buildAppTheme(), home: child),
);

void main() {
  group('纯函数：parseSavedWorkflowList / collectSavedWorkflowArgs / 错误人话', () {
    test('解析项目与全局工作流条目、实参声明与 invalid 计数', () {
      final parsed = parseSavedWorkflowList({
        'workflows': [
          {
            'name': 'daily-review',
            'description': '自动巡检今日提交',
            'scope': 'project',
            'path': '/ws/.zcode/workflows/daily-review.md',
            'args': {
              'branch': {
                'type': 'string',
                'required': true,
                'description': '目标分支',
              },
              'limit': {'type': 'number', 'default': 10},
              'dryRun': {'type': 'boolean', 'default': true},
              'extra': {'type': 'json'},
            },
          },
          {'name': '', 'description': '空名过滤'},
        ],
        'invalid': [
          {'path': '/ws/bad.md', 'reason': 'bad frontmatter'},
        ],
      }, fallbackScope: 'project');
      expect(parsed.entries, hasLength(1));
      expect(parsed.invalidCount, 1);
      final e = parsed.entries.first;
      expect(e.name, 'daily-review');
      expect(e.args, hasLength(4));
      expect(e.args[0].required, isTrue);
      expect(e.args[1].initialEditorText(), '10');
      expect(e.args[2].initialEditorText(), 'true');
    });

    test('collectSavedWorkflowArgs：必填、数字、JSON、布尔与省略语义', () {
      const specs = [
        SavedWorkflowArgSpec(name: 'branch', type: 'string', required: true),
        SavedWorkflowArgSpec(
          name: 'limit',
          type: 'number',
          hasDefault: true,
          defaultValue: 5,
        ),
        SavedWorkflowArgSpec(name: 'dryRun', type: 'boolean'),
        SavedWorkflowArgSpec(name: 'meta', type: 'json'),
      ];
      final bad = collectSavedWorkflowArgs(specs, {
        'branch': '   ',
        'limit': 'abc',
        'dryRun': 'true',
        'meta': '{bad',
      });
      expect(bad.ok, isFalse);
      expect(bad.errors.keys, containsAll(['branch', 'limit', 'meta']));

      final ok = collectSavedWorkflowArgs(specs, {
        'branch': 'main',
        'limit': '',
        'dryRun': 'true',
        'meta': '{"k":1}',
      });
      expect(ok.ok, isTrue);
      expect(ok.args, {
        'branch': 'main',
        'dryRun': true,
        'meta': {'k': 1},
      });
    });

    test('拒绝词表全部人话化，不裸露 reasonCode', () {
      for (final code in [
        'fault.command.capabilityUnsupported',
        'fault.command.savedWorkflowStartRejected.invalid_name',
        'fault.command.savedWorkflowStartRejected.not_found',
        'fault.command.savedWorkflowStartRejected.invalid_args',
        'fault.command.savedWorkflowStartRejected.compile_failed',
        'fault.command.savedWorkflowStartRejected.session_busy',
        'fault.command.savedWorkflowStartRejected.start_failed',
      ]) {
        final msg = savedWorkflowLaunchErrorMessage(code);
        expect(msg, isNotEmpty);
        expect(msg.contains('fault.'), isFalse);
      }
    });
  });

  test('transport 契约：listSavedWorkflows / startSavedWorkflow / deleteSession', () async {
    final calls = <(String, String, List<Object?>)>[];
    final ch = _SavedWfChannel((channel, method, args) async {
      calls.add((channel, method, args));
      if (method == 'listSavedWorkflows') {
        return {'workflows': const [], 'invalid': const []};
      }
      return {
        'status': 'accepted',
        'result': {'type': 'startSavedWorkflow', 'runId': 'r1', 'toolCallId': 't1'},
      };
    });
    final conv = _SavedWfBridge(ch).conversation({
      'workspacePath': '/example-ws',
      'workspaceIdentity': 'ws-wf',
    });

    await conv.listSavedWorkflows(scope: 'global');
    expect(calls.last.$1, Channels.zcodeAgent);
    expect(calls.last.$2, 'listSavedWorkflows');
    expect(calls.last.$3.first, {
      'workspacePath': '/example-ws',
      'workspaceIdentity': 'ws-wf',
      'scope': 'global',
    });

    await conv.startSavedWorkflow(
      'sess-1',
      name: 'daily',
      scope: 'project',
      args: const {'n': 2},
    );
    final env = (calls.last.$3.first as Map)['envelope'] as Map;
    expect(env['type'], 'startSavedWorkflow');
    expect(env['sessionId'], 'sess-1');
    expect(env['payload'], {
      'name': 'daily',
      'scope': 'project',
      'args': {'n': 2},
    });
    expect(env.containsKey('baseRevision'), isFalse);

    await conv.deleteSessionCommand('sess-1');
    final delEnv = (calls.last.$3.first as Map)['envelope'] as Map;
    expect(delEnv['type'], 'deleteSession');
    expect(delEnv['sessionId'], 'sess-1');
  });

  testWidgets('旅程：列表渲染 + 有参表单校验提交 + 拒绝人话提示', (tester) async {
    final app = _FakeSavedWfApp(
      projectResult: {
        'workflows': [
          {
            'name': 'quick-check',
            'description': '无参巡检',
            'scope': 'project',
            'path': '/ws/quick-check.md',
          },
          {
            'name': 'release-audit',
            'description': '带参数发布审查',
            'scope': 'project',
            'path': '/ws/release-audit.md',
            'args': {
              'tag': {'type': 'string', 'required': true},
              'strict': {'type': 'boolean', 'default': true},
            },
          },
        ],
        'invalid': const [],
      },
      globalResult: {
        'workflows': [
          {
            'name': 'global-digest',
            'description': '全局摘要',
            'scope': 'global',
            'path': '/global-wf/global-digest.md',
          },
        ],
        'invalid': const [],
      },
      onLaunch: ({required name, required scope, required args}) async {
        if (name == 'quick-check') {
          return (
            ok: false,
            sessionId: null,
            runId: null,
            errorCode: 'fault.command.savedWorkflowStartRejected.session_busy',
            errorMessage: null,
          );
        }
        return (
          ok: false,
          sessionId: null,
          runId: null,
          errorCode: 'fault.command.savedWorkflowStartRejected.compile_failed',
          errorMessage: 'syntax error at line 3',
        );
      },
    );

    await tester.pumpWidget(_host(app, const SavedWorkflowsPage()));
    await tester.pumpAndSettle();

    expect(find.text('quick-check'), findsOneWidget);
    expect(find.text('release-audit'), findsOneWidget);
    expect(find.text('global-digest'), findsOneWidget);

    // 无参直启 → session_busy 人话提示（无 raw reasonCode）
    await tester.tap(
      find.byKey(const ValueKey('saved-workflow-run-project-quick-check')),
    );
    await tester.pumpAndSettle();
    expect(app.launches, hasLength(1));
    expect(find.textContaining('会话忙'), findsOneWidget);
    expect(find.textContaining('fault.'), findsNothing);

    // 有参打开实参弹层 → 空提交被拦 → 填写后提交
    await tester.tap(
      find.byKey(const ValueKey('saved-workflow-run-project-release-audit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wf-args-submit')));
    await tester.pumpAndSettle();
    expect(find.text('此参数为必填项'), findsOneWidget);
    expect(app.launches, hasLength(1));

    await tester.enterText(
      find.byKey(const ValueKey('wf-arg-tag')),
      'v1.0.10',
    );
    await tester.tap(find.byKey(const ValueKey('wf-args-submit')));
    await tester.pumpAndSettle();
    expect(app.launches, hasLength(2));
    expect(app.launches.last.args, {'tag': 'v1.0.10', 'strict': true});
    expect(find.textContaining('syntax error at line 3'), findsOneWidget);
  });

  testWidgets('旧桌面不支持（-32602）：展示清晰升级引导', (tester) async {
    final app = _FakeSavedWfApp(
      listError: Exception('RPC -32602: Method not found'),
    );
    await tester.pumpWidget(_host(app, const SavedWorkflowsPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('请升级桌面端'), findsOneWidget);
  });

  group('AppState.launchSavedWorkflow 真实编排与回收不变量', () {
    Future<
      ({
        AppState app,
        _WfProbeStack stack,
        List<(String, String, List<Object?>)> calls,
      })
    >
    makeOrchestrationApp({
      required Future<dynamic> Function(
        String channel,
        String method,
        List<Object?> args,
      )
      onCall,
      Map<String, dynamic> workspace = const {
        'workspacePath': '/example-ws',
        'workspaceIdentity': 'ws-wf',
      },
      List<Map<String, dynamic>> seedProjects = const [],
      Map<String, dynamic>? projectIntent,
    }) async {
      final calls = <(String, String, List<Object?>)>[];
      final ch = _SavedWfChannel((channel, method, args) async {
        if (method == 'helloConversationV4') {
          return {
            'connectionId': 'conn-1',
            'capabilities': const <String, dynamic>{},
          };
        }
        if (method == 'initializeConversationV4') {
          return {'ok': true};
        }
        calls.add((channel, method, args));
        if (args.isEmpty ||
            args.first is! Map ||
            (args.first as Map)['envelope'] is! Map) {
          return null;
        }
        return onCall(channel, method, args);
      });
      final bridge = _SavedWfBridge(ch, projectIntent: projectIntent);
      final conv = bridge.conversation(workspace);
      final profile = AccountV2Profile(
        deviceSid: 'dev-wf',
        accountId: 'acc-1',
        label: '测试电脑',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final app = AppState(store: _MemProfiles([profile]));
      addTearDown(app.dispose);
      final stack = _WfProbeStack(
        profile,
        bridge: bridge,
        conv: conv,
        workspace: workspace,
        seedProjects: seedProjects,
      );
      app.debugRegisterStackForTest(stack);
      app.profiles = [profile];
      await app.activate(profile);
      return (app: app, stack: stack, calls: calls);
    }

    test('无活跃工作区返回 no_active_workspace', () async {
      final app = AppState();
      addTearDown(app.dispose);
      final res = await app.launchSavedWorkflow(
        name: 'daily',
        scope: 'project',
      );
      expect(res.ok, isFalse);
      expect(res.errorCode, 'no_active_workspace');
    });

    test('projectId 遵循 rootMatched 不变量，accepted 与 duplicate 均成功且不误回收', () async {
      var seq = 0;
      final h = await makeOrchestrationApp(
        workspace: const {
          'workspacePath': '/example-root',
          'workspaceIdentity': '/example-root',
        },
        seedProjects: const [
          {
            'id': 'proj-root',
            'name': 'Root',
            'roots': [
              {'rootPath': '/example-root'},
            ],
          },
        ],
        onCall: (channel, method, args) async {
          final req = args.first as Map;
          final env = req['envelope'] as Map;
          if (env['type'] == 'createSession') {
            return {
              'status': 'accepted',
              'result': {'sessionId': 'sess-${++seq}'},
            };
          }
          if (env['type'] == 'startSavedWorkflow') {
            return {
              'status': seq == 1 ? 'accepted' : 'duplicate',
              'result': {
                'type': 'startSavedWorkflow',
                'runId': 'run-$seq',
              },
            };
          }
          return {'status': 'accepted'};
        },
      );

      final r1 = await h.app.launchSavedWorkflow(
        name: 'daily',
        scope: 'project',
      );
      expect(r1.ok, isTrue);
      expect(r1.sessionId, 'sess-1');
      expect(r1.runId, 'run-1');
      final createReq = h.calls
          .firstWhere(
            (c) =>
                c.$3.isNotEmpty &&
                c.$3.first is Map &&
                (c.$3.first as Map)['envelope'] is Map &&
                ((c.$3.first as Map)['envelope'] as Map)['type'] ==
                    'createSession',
          )
          .$3
          .first as Map;
      expect(createReq['projectId'], 'proj-root');

      // duplicate ACK 也必须视为成功，不得删会话。
      final r2 = await h.app.launchSavedWorkflow(
        name: 'daily',
        scope: 'project',
      );
      expect(r2.ok, isTrue);
      expect(r2.sessionId, 'sess-2');
      final deletes = h.calls.where((c) {
        if (c.$3.isEmpty || c.$3.first is! Map) return false;
        final env = (c.$3.first as Map)['envelope'];
        return env is Map && env['type'] == 'deleteSession';
      });
      expect(deletes, isEmpty);
    });

    test('工作区非项目根时不传 projectId（防 cwd-not-in-roots）；拒绝或异常立即回收空会话', () async {
      final h = await makeOrchestrationApp(
        workspace: const {
          'workspacePath': '/other-dir',
          'workspaceIdentity': '/other-dir',
        },
        seedProjects: const [
          {
            'id': 'proj-root',
            'name': 'Root',
            'roots': [
              {'rootPath': '/example-root'},
            ],
          },
        ],
        onCall: (channel, method, args) async {
          final env = (args.first as Map)['envelope'] as Map;
          if (env['type'] == 'createSession') {
            return {
              'status': 'accepted',
              'result': {'sessionId': 'sess-recycle'},
            };
          }
          if (env['type'] == 'startSavedWorkflow') {
            return {
              'status': 'rejected',
              'reasonCode':
                  'fault.command.savedWorkflowStartRejected.compile_failed',
              'message': 'line 7',
            };
          }
          return {'status': 'accepted'};
        },
      );

      final rejected = await h.app.launchSavedWorkflow(
        name: 'broken',
        scope: 'project',
      );
      expect(rejected.ok, isFalse);
      expect(
        rejected.errorCode,
        'fault.command.savedWorkflowStartRejected.compile_failed',
      );
      final createReq = h.calls
          .firstWhere(
            (c) =>
                c.$3.isNotEmpty &&
                c.$3.first is Map &&
                (c.$3.first as Map)['envelope'] is Map &&
                ((c.$3.first as Map)['envelope'] as Map)['type'] ==
                    'createSession',
          )
          .$3
          .first as Map;
      expect(
        createReq.containsKey('projectId'),
        isFalse,
        reason: '非项目根工作区不得传 projectId',
      );
      final deletedIds = [
        for (final c in h.calls)
          if (c.$3.isNotEmpty &&
              c.$3.first is Map &&
              (c.$3.first as Map)['envelope'] is Map &&
              ((c.$3.first as Map)['envelope'] as Map)['type'] ==
                  'deleteSession')
            ((c.$3.first as Map)['envelope'] as Map)['sessionId'],
      ];
      expect(deletedIds, ['sess-recycle'], reason: '启动被拒须立刻回收空会话');
    });

    test('startSavedWorkflow 抛异常回收空会话；createSession 失败不误调 deleteSession', () async {
      var failCreate = false;
      final h = await makeOrchestrationApp(
        onCall: (channel, method, args) async {
          final env = (args.first as Map)['envelope'] as Map;
          if (env['type'] == 'createSession') {
            if (failCreate) throw StateError('create failed');
            return {
              'status': 'accepted',
              'result': {'sessionId': 'sess-throw'},
            };
          }
          if (env['type'] == 'startSavedWorkflow') {
            throw TimeoutException('relay timeout');
          }
          return {'status': 'accepted'};
        },
      );

      final r1 = await h.app.launchSavedWorkflow(name: 't', scope: 'global');
      expect(r1.ok, isFalse);
      expect(r1.errorCode, 'exception');
      expect(
        h.calls.where(
          (c) =>
              c.$3.isNotEmpty &&
              c.$3.first is Map &&
              (c.$3.first as Map)['envelope'] is Map &&
              ((c.$3.first as Map)['envelope'] as Map)['type'] ==
                  'deleteSession',
        ),
        hasLength(1),
      );

      h.calls.clear();
      failCreate = true;
      final r2 = await h.app.launchSavedWorkflow(name: 't', scope: 'global');
      expect(r2.ok, isFalse);
      expect(
        h.calls.where(
          (c) =>
              c.$3.isNotEmpty &&
              c.$3.first is Map &&
              (c.$3.first as Map)['envelope'] is Map &&
              ((c.$3.first as Map)['envelope'] as Map)['type'] ==
                  'deleteSession',
        ),
        isEmpty,
        reason: '未创建会话时不得调用 deleteSession',
      );
    });

    test('并发启动防重入：在飞期间二次调用直接返回 launch_in_flight', () async {
      final gate = Completer<Map<String, dynamic>>();
      final h = await makeOrchestrationApp(
        onCall: (channel, method, args) async {
          final env = (args.first as Map)['envelope'] as Map;
          if (env['type'] == 'createSession') {
            return gate.future;
          }
          return {
            'status': 'accepted',
            'result': {'type': 'startSavedWorkflow', 'runId': 'run-1'},
          };
        },
      );
      final first = h.app.launchSavedWorkflow(name: 'a', scope: 'project');
      final second = await h.app.launchSavedWorkflow(
        name: 'b',
        scope: 'project',
      );
      expect(second.ok, isFalse);
      expect(second.errorCode, 'launch_in_flight');
      gate.complete({
        'status': 'accepted',
        'result': {'sessionId': 'sess-first'},
      });
      final r1 = await first;
      expect(r1.ok, isTrue);
    });
  });

  testWidgets('旅程：启动成功跳转会话页 + 部分失败警告 + 空态/非法文件/通用错误重试', (
    tester,
  ) async {
    // 1. 成功启动跳转 ConversationPage + 双击互斥（在飞中二次点击不重复触发）
    final launchGate =
        Completer<
          ({
            bool ok,
            String? sessionId,
            String? runId,
            String? errorCode,
            String? errorMessage,
          })
        >();
    final navApp = _FakeSavedWfApp(
      projectResult: {
        'workflows': [
          {
            'name': 'ship-now',
            'description': '一键发布',
            'scope': 'project',
            'path': '/ws/ship-now.md',
          },
        ],
        'invalid': [
          {'path': '/ws/bad.md', 'reason': 'yaml error'},
        ],
      },
      globalError: Exception('global read failed'),
      onLaunch: ({required name, required scope, required args}) =>
          launchGate.future,
    );
    await tester.pumpWidget(_host(navApp, const SavedWorkflowsPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('部分工作流列表加载失败'), findsOneWidget);
    expect(find.textContaining('另有 1 个工作流文件解析失败'), findsOneWidget);

    final runBtn = find.byKey(const ValueKey('saved-workflow-run-project-ship-now'));
    await tester.tap(runBtn);
    await tester.pump();
    await tester.tap(runBtn);
    await tester.pump();
    expect(navApp.launches, hasLength(1), reason: '启动在飞期间防双击重复建会话');

    launchGate.complete((
      ok: true,
      sessionId: 'sess-ok-1',
      runId: 'run-ok-1',
      errorCode: null,
      errorMessage: null,
    ));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationPage), findsOneWidget);
  });

  testWidgets('旅程：通用错误态可重试与空态引导', (tester) async {
    final errApp = _FakeSavedWfApp(
      listError: Exception('network down'),
    );
    await tester.pumpWidget(_host(errApp, const SavedWorkflowsPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('加载已保存工作流失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    final emptyApp = _FakeSavedWfApp(
      projectResult: const {'workflows': [], 'invalid': []},
      globalResult: const {'workflows': [], 'invalid': []},
    );
    await tester.pumpWidget(
      _host(emptyApp, const SavedWorkflowsPage(key: ValueKey('empty-wf'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无已保存工作流'), findsOneWidget);
  });

  testWidgets('英文界面 + 窄屏 320dp + 1.3 字号：无缺译无溢出', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final app = _FakeSavedWfApp(
      projectResult: {
        'workflows': [
          {
            'name': 'very-long-saved-workflow-name-for-narrow-screen-check',
            'description': 'A long workflow description verifying ellipsis',
            'scope': 'project',
            'path': '/ws/wf.md',
            'args': {
              'targetBranch': {'type': 'string', 'required': true},
              'dryRun': {'type': 'boolean', 'default': false},
            },
          },
        ],
        'invalid': const [],
      },
      globalResult: const {'workflows': [], 'invalid': []},
    );
    await tester.pumpWidget(_host(app, const SavedWorkflowsPage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(L10n.missingTranslations, isEmpty);

    await tester.tap(
      find.byKey(
        const ValueKey(
          'saved-workflow-run-project-very-long-saved-workflow-name-for-narrow-screen-check',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(L10n.missingTranslations, isEmpty);
  });

  group('真字体渲染采集：已保存工作流页（浅/深）', () {
    setUpAll(loadRealFonts);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('渲染·已保存工作流列表（$tag）', (tester) async {
        tester.view.physicalSize = const Size(375, 806);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final app = _FakeSavedWfApp(
          projectResult: {
            'workflows': [
              {
                'name': 'quick-check',
                'description': '无参代码质量巡检与回归验证',
                'scope': 'project',
                'path': '/ws/quick-check.md',
              },
              {
                'name': 'release-audit',
                'description': '带参数发布前安全与合规复核',
                'scope': 'project',
                'path': '/ws/release-audit.md',
                'args': {
                  'tag': {'type': 'string', 'required': true},
                  'strict': {'type': 'boolean', 'default': true},
                },
              },
            ],
            'invalid': const [],
          },
          globalResult: {
            'workflows': [
              {
                'name': 'global-digest',
                'description': '跨项目日报摘要与风险汇总',
                'scope': 'global',
                'path': '/global-wf/global-digest.md',
              },
            ],
            'invalid': const [],
          },
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: realFontShotKey,
            child: AppStateScope(
              app: app,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: reviewTheme(brightness),
                home: const SavedWorkflowsPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('quick-check'), findsOneWidget);
        expect(find.text('release-audit'), findsOneWidget);
        expect(find.text('global-digest'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'saved-workflows-$tag-zh');
      });
    }
  });

  group('回归：旧版桌面端错误码与仅全局不支持降级', () {
    test('isSavedWorkflowListUnsupportedError 识别 ChannelRpcError.data.code -32601/-32602', () {
      expect(
        isSavedWorkflowListUnsupportedError(
          ChannelRpcError('Invalid params', const {'code': -32602}),
        ),
        isTrue,
      );
      expect(
        isSavedWorkflowListUnsupportedError(
          ChannelRpcError('unknown error', const {'code': -32601}),
        ),
        isTrue,
      );
      expect(
        isSavedWorkflowListUnsupportedError(Exception('method-not-found')),
        isTrue,
      );
      expect(
        isSavedWorkflowListUnsupportedError(Exception('timeout')),
        isFalse,
      );
    });

    testWidgets('仅 global scope 不支持且当前项目为空列表时不误判整页不支持', (tester) async {
      final app = _FakeSavedWfApp(
        projectResult: const {'workflows': [], 'invalid': []},
        globalError: ChannelRpcError('Invalid params', const {'code': -32602}),
      );
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const SavedWorkflowsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无已保存工作流'), findsOneWidget);
      expect(find.textContaining('当前桌面端版本不支持'), findsNothing);
    });
  });
}
