// 项目排序（2026-10-26 拍板③，官方 preferences.reorder 同语义=本地
// 偏好不同步）：纯函数序应用 + 排序弹层拖动保存 + chip 行尾显式入口。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_catalog.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _OrderApp extends AppState {
  List<String> order = const [];

  final List<Map<String, dynamic>> base = [
    {'id': 'p-1', 'name': '甲'},
    {'id': 'p-2', 'name': '乙'},
    {'id': 'p-3', 'name': '丙'},
    {'id': 'p-4', 'name': '新'},
    conversationsPseudoProject(),
  ];

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  List<Map<String, dynamic>> get sidebarProjects =>
      applyProjectOrder(base, order.isEmpty ? null : order);

  @override
  List<Map<String, dynamic>> get unclassifiedTasks => const [];

  @override
  List<Map<String, dynamic>> get workspaceTasks => [
        for (final p in base)
          if ('${p['id']}' != conversationsPseudoProjectId)
            {
              'taskId': 't-${p['id']}',
              'title': '任务${p['name']}',
              'projectId': p['id'],
              'workspacePath': 'D:/示例/${p['id']}',
              'updatedAt': 1800000000000,
              'displayStatus': 'idle',
            },
      ];

  @override
  List<Map<String, dynamic>> get projectTasks => workspaceTasks;

  List<String>? savedIds;
  bool cleared = false;
  bool failSave = false;

  @override
  bool get hasCustomProjectOrder => order.isNotEmpty;

  @override
  Future<void> setProjectOrder(List<String> ids) async {
    if (failSave) throw StateError('disk_full');
    savedIds = ids;
    order = ids;
    notifyListeners();
  }

  @override
  Future<void> clearProjectOrder() async {
    if (failSave) throw StateError('disk_full');
    cleared = true;
    order = const [];
    notifyListeners();
  }
}

class _OrderChannel extends ChannelClient {
  _OrderChannel(this.onCall) : super(sendBody: (_) {});
  final Future<dynamic> Function(String channel, String method, List<Object?> args)
  onCall;
  final List<({String channel, String event, void Function(dynamic) cb})>
  listeners = [];

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) => onCall(channel, method, args);

  @override
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    final entry = (channel: channel, event: event, cb: onEvent);
    listeners.add(entry);
    return () => listeners.remove(entry);
  }

  void emitEvent(String channel, String event, dynamic data) {
    for (final l in List.of(listeners)) {
      if (l.channel == channel && l.event == event) {
        l.cb(data);
      }
    }
  }
}

class _OrderBridge implements BridgeSession {
  _OrderBridge(this.channel);
  _OrderChannel channel;
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
  String? get workspaceKey => 'ws-order';
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

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const TaskCenterPage(),
      ),
    );

// 抽屉化适配（2026-11-17）：排序入口迁侧边抽屉；项目分组断言限定抽屉。
Future<void> _openDrawer(WidgetTester tester) async {
  tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  // 定帧泵（pumpAndSettle 会被运行中任务的 RunningPulseDot 永续动画
  // 卡到超时）——抽屉滑入动画 ~246ms，8×50ms 足够。
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder inDrawer(Finder f) =>
    find.descendant(of: find.byType(Drawer), matching: f);

void main() {
  test('applyProjectOrder：命中按序/未记录追加/伪项目恒尾/null 原序', () {
    final entries = <Map<String, dynamic>>[
      {'id': 'p-1', 'name': '一'},
      {'id': 'p-2', 'name': '二'},
      {'id': 'p-3', 'name': '三'},
      {'id': 'p-new', 'name': '新'},
      conversationsPseudoProject(),
    ];
    final ordered = applyProjectOrder(entries, ['p-3', 'p-1']);
    expect(ordered.map((e) => e['id']),
        ['p-3', 'p-1', 'p-2', 'p-new', conversationsPseudoProjectId],
        reason: '命中前置按序；未记录按原序追加；「任务」恒尾');
    expect(applyProjectOrder(entries, null), same(entries),
        reason: 'null=原序不动');
    expect(applyProjectOrder(entries, []), same(entries));
  });

  testWidgets('主页更多菜单排序入口开弹层，拖动即存并即时生效', (tester) async {
    // 抽屉化批②：项目组断言在抽屉列表内——画布加高保证四个组头
    // 都在懒构建视口内（806 下第四组在视口外不挂载）。
    tester.view.physicalSize = const Size(375, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _OrderApp();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // B 方案：排序入口迁抽屉（原「更多」菜单退役）。
    expect(find.byKey(const ValueKey('project-order-entry')), findsNothing);
    await _openDrawer(tester);
    await tester.tap(find.byKey(const ValueKey('drawer-project-order')));
    await tester.pumpAndSettle();
    expect(find.text('调整项目顺序'), findsOneWidget);

    // 拖第一项（甲项目）到第三位：按住手柄长按拖动。
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(app.savedIds, ['p-2', 'p-3', 'p-1', 'p-4'],
        reason: '拖完即存（伪项目不入序）');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 项目分组视图迁抽屉：开抽屉断言项目组按新顺序即时重排。
    await _openDrawer(tester);
    double groupY(String id) => tester
        .getTopLeft(inDrawer(find.byKey(ValueKey('home-group:project:$id'))))
        .dy;
    expect(groupY('p-2') < groupY('p-3'), isTrue);
    expect(groupY('p-3') < groupY('p-1'), isTrue);
    expect(groupY('p-1') < groupY('p-4'), isTrue,
        reason: '项目组按新顺序即时重排');

    // 再次打开排序弹层（抽屉仍展开）：出现「恢复跟随桌面」，点击后
    // 复位回桌面基线顺序。
    await tester.tap(find.byKey(const ValueKey('drawer-project-order')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('project-order-reset-desktop')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('project-order-reset-desktop')));
    await tester.pumpAndSettle();
    expect(app.cleared, isTrue);
    expect(
      find.byKey(const ValueKey('project-order-reset-desktop')),
      findsNothing,
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    // 抽屉内项目组断言：弹层关闭后抽屉已收起，重新打开再断言。
    await _openDrawer(tester);
    expect(groupY('p-1') < groupY('p-2'), isTrue, reason: '恢复跟随桌面顺序');
  });

  test('parseProjectTree + applyDesktopProjectOrder：桌面侧栏顺序默认生效', () {
    final parsed = parseProjectTree({
      'projects': [
        {'id': 'p-1', 'name': '一', 'hostId': 'local', 'position': 0},
        {'id': 'p-2', 'name': '二', 'hostId': 'local', 'position': 1},
        {'id': 'p-3', 'name': '三', 'hostId': 'remote-a', 'position': 2},
        {'id': 'p-new', 'name': '新', 'position': 3},
      ],
      'tasks': const [],
      'projectOrder': [
        {'hostId': 'remote-a', 'projectId': 'p-3'},
        {'hostId': 'local', 'projectId': 'p-2'},
        {'hostId': '', 'projectId': 'p-1'},
        {'hostId': 'local', 'projectId': 'p-2'},
        {'hostId': 'local', 'projectId': 'p-1'},
      ],
    });
    expect(parsed.projectOrder.length, 3);
    final entries = [
      ...visibleProjectsOf(parsed.projects),
      conversationsPseudoProject(),
    ];
    final ordered = applyDesktopProjectOrder(entries, parsed.projectOrder);
    expect(
      ordered.map((e) => e['id']),
      ['p-3', 'p-2', 'p-1', 'p-new', conversationsPseudoProjectId],
      reason: '精确匹配 (hostId, id) 排在前，新增项目保原序在后，任务伪项目恒尾',
    );
    expect(applyDesktopProjectOrder(entries, const []), same(entries));

    // 无 hostId 时唯一 projectId 兜底命中；多 host 同 id 不错配。
    final uniqueFallback = applyDesktopProjectOrder(
      [
        {'id': 'p-1', 'name': '一'},
        {'id': 'p-2', 'name': '二'},
      ],
      const [(hostId: 'local', projectId: 'p-2')],
    );
    expect(uniqueFallback.map((e) => e['id']), ['p-2', 'p-1']);

    final ambiguous = applyDesktopProjectOrder(
      [
        {'id': 'same', 'hostId': 'host-b', 'name': 'B'},
        {'id': 'other', 'hostId': 'local', 'name': 'Other'},
        {'id': 'same', 'hostId': 'host-a', 'name': 'A'},
      ],
      const [
        (hostId: 'host-a', projectId: 'same'),
        (hostId: 'local', projectId: 'other'),
      ],
    );
    expect(
      ambiguous.map((e) => '${e['hostId']}:${e['id']}'),
      ['host-a:same', 'local:other', 'host-b:same'],
      reason: '带明确不同 hostId 的未排名项目不得跨 host 抢占同名 projectId 排名',
    );
  });

  test('TaskCatalog：loadProjects 应用桌面 projectOrder + state:projects 广播与 bridge.recovered 重订', () async {
    var desktopOrder = [
      {'hostId': 'local', 'projectId': 'p-2'},
      {'hostId': 'local', 'projectId': 'p-1'},
    ];
    _OrderChannel buildChannel() => _OrderChannel((channel, method, args) async {
      if (channel == Channels.project && method == 'readTree') {
        return {
          'projects': [
            {'id': 'p-1', 'name': '一', 'hostId': 'local', 'position': 0},
            {'id': 'p-2', 'name': '二', 'hostId': 'local', 'position': 1},
          ],
          'tasks': const [],
          'projectOrder': desktopOrder,
        };
      }
      return null;
    });
    final ch1 = buildChannel();
    final bridge = _OrderBridge(ch1);
    final catalog = TaskCatalog(
      bridgeProvider: () => bridge,
      conversationProvider: () => null,
      activeWorkspaceProvider: () => null,
      workspacesProvider: () => const [],
      disposedProvider: () => false,
      onLog: (_) {},
      onNotify: () {},
      onCacheWrite: () {},
      onTaskListChanged: () {},
      onTaskListRebuilt: (_) {},
    );
    addTearDown(catalog.dispose);

    catalog.attachBridge(bridge);
    await catalog.loadProjects();
    expect(catalog.projects.map((p) => p['id']), ['p-2', 'p-1']);
    final v1 = catalog.projectsVersion;

    // 模拟桌面端拖动侧栏顺序并广播 state:projects
    desktopOrder = [
      {'hostId': 'local', 'projectId': 'p-1'},
      {'hostId': 'local', 'projectId': 'p-2'},
    ];
    ch1.emitEvent(Channels.broadcast, 'onMessage', {'channel': 'state:projects'});
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(catalog.projects.map((p) => p['id']), ['p-1', 'p-2']);
    expect(catalog.projectsVersion, greaterThan(v1));

    // 模拟桥断线重开：旧 ChannelClient 销毁并 swap 为全新 ChannelClient + recovered++
    final ch2 = buildChannel();
    bridge.channel = ch2;
    desktopOrder = [
      {'hostId': 'local', 'projectId': 'p-2'},
      {'hostId': 'local', 'projectId': 'p-1'},
    ];
    bridge.recovered.value++;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(catalog.projects.map((p) => p['id']), ['p-2', 'p-1'],
        reason: '桥恢复后即使原 readTreeStatus==ok 也需收敛断连期间的新桌面顺序');

    // 桥恢复后新 ChannelClient 上的 state:projects 广播仍能触发实时同步
    desktopOrder = [
      {'hostId': 'local', 'projectId': 'p-1'},
      {'hostId': 'local', 'projectId': 'p-2'},
    ];
    ch2.emitEvent(Channels.broadcast, 'onMessage', {'channel': 'state:projects'});
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(catalog.projects.map((p) => p['id']), ['p-1', 'p-2'],
        reason: '桥恢复后必须重订新 ChannelClient 的 state:projects 广播');
  });

  test('UiPrefs.setProjectOrder / clearProjectOrder 写删盘失败时回滚内存态并返回 false', () async {
    final storage = _FlakyOrderStorage();
    final prefs = UiPrefs(storage: storage);
    await prefs.load();

    expect(await prefs.setProjectOrder('dev-1', ['p-2', 'p-1']), isTrue);
    expect(prefs.projectOrder('dev-1'), ['p-2', 'p-1']);

    storage.failWrite = true;
    expect(await prefs.setProjectOrder('dev-1', ['p-1', 'p-2']), isFalse);
    expect(prefs.projectOrder('dev-1'), ['p-2', 'p-1'], reason: '写盘失败必须回滚内存');

    storage.failDelete = true;
    expect(await prefs.clearProjectOrder('dev-1'), isFalse);
    expect(prefs.projectOrder('dev-1'), ['p-2', 'p-1'], reason: '删盘失败必须回滚内存');
  });

  testWidgets('排序弹层内联状态/失败提示 + 英文与窄屏 320dp 1.3 字号无缺译无溢出', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final app = _OrderApp()..order = ['p-2', 'p-1', 'p-3', 'p-4'];
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await _openDrawer(tester);
    await tester.tap(find.byKey(const ValueKey('drawer-project-order')));
    await tester.pumpAndSettle();

    // 模拟恢复失败 → 弹层内联错误提示
    app.failSave = true;
    await tester.tap(find.byKey(const ValueKey('project-order-reset-desktop')));
    await tester.pumpAndSettle();
    expect(find.textContaining('恢复失败'), findsOneWidget);

    // 恢复正常 → 点击「恢复跟随桌面」出现内联确认文案
    app.failSave = false;
    await tester.tap(find.byKey(const ValueKey('project-order-reset-desktop')));
    await tester.pumpAndSettle();
    expect(find.text('已恢复跟随桌面顺序'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 英文模式无缺译无溢出
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    app.order = ['p-2', 'p-1', 'p-3', 'p-4'];
    await _openDrawer(tester);
    await tester.tap(find.byKey(const ValueKey('drawer-project-order')));
    await tester.pumpAndSettle();
    expect(find.text('Follow desktop'), findsOneWidget);
    expect(L10n.missingTranslations, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _FlakyOrderStorage extends FlutterSecureStorage {
  _FlakyOrderStorage()
    : super(
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  final Map<String, String> data = {};
  bool failWrite = false;
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
    if (failWrite) throw PlatformException(code: 'IO', message: 'write failed');
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
    if (failDelete) throw PlatformException(code: 'IO', message: 'delete failed');
    data.remove(key);
  }
}
