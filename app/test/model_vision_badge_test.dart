// 模型「视觉」能力标签·会话模型弹层（官方桌面 ModelConfigSelect 行内
// 徽标对位）。
//
// 夹具=官方 model-selection.getView 真实 wire 形态，经生产解析路径
// （通道 getView → modelSelectionOptions → 弹层）到达界面——锁的是
// 「目录说支持图片 → 行内出标签」整条链路，而非手搓的目录条目。
// 覆盖两条取数路径：
// - 草稿：目录直出；
// - 会话内：会话目录本身不带能力字段（官方 configOptions 只投影到
//   providerLabel），由 getView 目录按 provider+model 补齐。
//
// 末尾为真字体渲染采集：字体可得的机器上把弹层按手机
// 像素比渲成 PNG 落盘，供人工目检；不可得=只跑断言。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/composer_panels.dart';
import 'package:zcode_pocket/ui/subagents_page.dart'
    show showSubagentModelSheet;

import 'real_font_snapshot.dart';
import 'vision_badge_fixture.dart';

// ---------------------------------------------------------------- 夹具

/// 官方 serializeRegistryModelConfig 形态；image=null 表示模型 config
/// 不带 properties（目录没给事实）。
Map<String, dynamic> _model(String id, {bool? image}) => {
  'modelId': id,
  'config': {
    'enabled': true,
    if (image != null)
      'properties': {
        'requiresMfjsToolSchema': false,
        'contextWindow': 200000,
        'inputFormat': {
          'supportsText': true,
          'supportsImage': image,
          'supportsVideo': false,
          'supportsAudio': false,
          'supportsPdf': false,
        },
        'outputFormat': {'supportsText': true},
        'supportsToolCall': true,
        'supportsJsonSchemaOutput': false,
        'supportsNativeWebSearch': false,
        'supportsMidConversationSystem': false,
      },
    'optionSpecs': {
      'reasoningLevel': {'values': ['nothink', 'think']},
    },
  },
};

Map<String, dynamic> _planAccess({
  String mode = 'individual-coding-plan',
}) => {
  'type': 'zhipu-account',
  'accountType': 'bigmodel',
  'mode': mode,
  'entitled': true,
};

const _apiAccess = {'type': 'api-key'};

/// 官方 projectModelSelectionProviderView 形态。
Map<String, dynamic> _provider(
  String pid, {
  required String name,
  required Map<String, dynamic> access,
  required List<Map<String, dynamic>> models,
}) => {
  'providerId': pid,
  'providerName': name,
  'templateId': 'tpl-example',
  'config': {
    'group': 'standard-personal',
    'access': access,
    'api': {'type': 'glm', 'baseUrl': 'https://example.invalid/v4'},
  },
  'models': models,
};

Map<String, dynamic> _view(List<Map<String, dynamic>> providers) => {
  'revision': 3,
  'providers': providers,
};

const _planPid = visionPlanPid;
const _apiPid = visionApiPid;

/// 两种接入方式 × 三种标签形态（标 / 套餐例外不标 / 无能力不标）。
Map<String, dynamic> _widgetView() => _view([
  _provider(
    _planPid,
    name: 'BigModel',
    access: _planAccess(),
    models: [
      _model('glm-5.3', image: true),
      _model('glm-5.3-flash', image: true),
      _model('glm-5.3-air', image: false),
    ],
  ),
  _provider(
    _apiPid,
    name: 'OCG',
    access: _apiAccess,
    models: [
      _model('claude-sonnet-4.5', image: true),
      _model('glm-5.3', image: true),
      _model('deepseek-v3', image: false),
    ],
  ),
]);

class _ViewChannel extends ChannelClient {
  _ViewChannel(this.view) : super(sendBody: (_) {});

  /// null=目录不可用（getView 无响应）。
  final Map<String, dynamic>? view;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return method == 'getView' ? view : null;
  }
}

class _ViewBridge implements BridgeSession {
  _ViewBridge(this.channel);

  final _ViewChannel channel;

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
  String? get workspaceKey => 'ws-vision';
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

/// 目录经真实 transport 解析（生产路径）；sessionOptions=会话目录
/// （getTaskConfigOptions 的返回，官方 configOptions 形状）。
class _VisionApp extends AppState {
  _VisionApp(this.view, {List<ConfigOption>? sessionOptions})
    : sessionOptions = sessionOptions ?? const [];

  final Map<String, dynamic>? view;
  final List<ConfigOption> sessionOptions;

  @override
  late final BridgeSession bridge = _ViewBridge(_ViewChannel(view));

  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspacePath': '/example-workspace',
    'workspaceIdentity': 'ws-vision',
  };

  ConversationTransport get _conv => bridge.conversation(activeWorkspace!);

  @override
  Future<List<dynamic>> modelSelectionOptions() async =>
      _conv.modelSelectionOptions();

  @override
  Future<Map<String, dynamic>?> modelSelectionView() async =>
      _conv.modelSelectionView();

  @override
  Future<List<dynamic>> getTaskConfigOptions(String taskId) async =>
      sessionOptions;
}

// ---------------------------------------------------------------- 工具

/// 会话目录（官方 zcodeSessionSettingsToZCodeConfigOptions 投影形状：
/// 模型条目只有 value/name/providerId/providerLabel/思考档，无能力字段）。
List<ConfigOption> _sessionOptions({bool withHiddenProvider = false}) => [
  ConfigOption.fromMap({
    'id': 'model',
    'name': 'Model',
    'category': 'model',
    'type': 'select',
    'currentValue': '$_planPid/glm-5.3-flash',
    'options': [
      {
        'value': '$_planPid/glm-5.3',
        'name': 'GLM-5.3',
        'modelProviderId': _planPid,
        'modelProviderName': 'BigModel',
        'modelThoughtLevels': ['nothink', 'think'],
      },
      {
        'value': '$_planPid/glm-5.3-flash',
        'name': 'GLM-5.3-Flash',
        'modelProviderId': _planPid,
        'modelProviderName': 'BigModel',
        'modelThoughtLevels': ['nothink', 'think'],
      },
      {
        'value': '$_planPid/glm-5.3-air',
        'name': 'GLM-5.3-Air',
        'modelProviderId': _planPid,
        'modelProviderName': 'BigModel',
      },
      {
        'value': '$_apiPid/claude-sonnet-4.5',
        'name': 'Claude Sonnet 4.5',
        'modelProviderId': _apiPid,
        'modelProviderName': 'OCG',
      },
      {
        'value': '$_apiPid/glm-5.3',
        'name': 'GLM-5.3',
        'modelProviderId': _apiPid,
        'modelProviderName': 'OCG',
      },
      {
        'value': '$_apiPid/deepseek-v3',
        'name': 'DeepSeek V3',
        'modelProviderId': _apiPid,
        'modelProviderName': 'OCG',
      },
      // 目录里不存在的 provider（服务端已滤 hidden 的派生执行入口）
      // ——既有白名单语义：会话目录带着它也不得进弹层。
      if (withHiddenProvider)
        {
          'value': 'account:hidden-plan/executor',
          'name': 'executor',
          'modelProviderId': 'account:hidden-plan',
          'modelProviderName': 'hidden',
        },
    ],
  }),
];

Widget _sheetHost(
  AppState app,
  Brightness brightness,
  VoidCallback open,
) => RepaintBoundary(
  key: realFontShotKey,
  child: AppStateScope(
    app: app,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: reviewTheme(brightness),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // 图标钮（无文案）：英文轮/缺译收集不受宿主按钮干扰。
          child: IconButton(
            key: const ValueKey('open'),
            onPressed: open,
            icon: const Icon(Icons.tune),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _usePhoneSize(WidgetTester tester, {Size size = const Size(375, 806)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _openSheet(
  WidgetTester tester,
  AppState app, {
  String? sessionId,
  String? pendingModelId,
  String? pendingModelProvider,
  Brightness brightness = Brightness.light,
  Size size = const Size(375, 806),
}) async {
  await _usePhoneSize(tester, size: size);
  late BuildContext hostContext;
  await tester.pumpWidget(
    _sheetHost(app, brightness, () {
      showModelSheet(
        hostContext,
        sessionId: sessionId,
        state: ConversationState(),
        pendingModelId: pendingModelId,
        pendingModelProvider: pendingModelProvider,
      );
    }),
  );
  hostContext = tester.element(find.byKey(const ValueKey('open')));
  await tester.tap(find.byKey(const ValueKey('open')));
  await _settle(tester, frames: 15);
}

String _row(String pid, String model) => 'model-row-$pid/$model';

Finder _rowOf(String pid, String model) =>
    find.byKey(ValueKey(_row(pid, model)));

Finder _badgeIn(String pid, String model) =>
    visionBadgeInRow(_row(pid, model));

Finder _checkIn(String pid, String model) => find.descendant(
  of: _rowOf(pid, model),
  matching: find.byIcon(Icons.check),
);

/// 展开某 provider 分组（默认只有选中组/首组展开）。
Future<void> _expandGroup(WidgetTester tester, String pid) async {
  final header = find.byKey(ValueKey('model-group-$pid'));
  await tester.ensureVisible(header);
  await tester.tap(header);
  await _settle(tester);
}

/// 选中行：✓ 在标签右侧（胶囊右缘=文字右缘+4 内距+1 描边，再留间距）。
void _expectCheckRightOfBadge(WidgetTester tester, String pid, String model) {
  final check = _checkIn(pid, model);
  expect(check, findsOneWidget);
  final badgeRight = tester.getTopRight(_badgeIn(pid, model)).dx;
  final checkLeft = tester
      .renderObject<RenderBox>(check)
      .localToGlobal(Offset.zero)
      .dx;
  expect(checkLeft - (badgeRight + 5), greaterThanOrEqualTo(6));
}

/// 三种标签形态的标准断言（两路径共用；前提=两组均已展开）。
void _expectStandardBadges() {
  expect(_badgeIn(_planPid, 'glm-5.3'), findsNothing,
      reason: '官方展示例外：套餐接入下的 glm-5.3 不标视觉');
  expect(_badgeIn(_planPid, 'glm-5.3-flash'), findsOneWidget,
      reason: '套餐下的其他型号不受例外影响');
  expect(_badgeIn(_planPid, 'glm-5.3-air'), findsNothing,
      reason: '目录说支持图片=false：不标');
  expect(_badgeIn(_apiPid, 'claude-sonnet-4.5'), findsOneWidget);
  expect(_badgeIn(_apiPid, 'glm-5.3'), findsOneWidget,
      reason: '例外只限套餐接入——API 渠道的 glm-5.3 照标');
  expect(_badgeIn(_apiPid, 'deepseek-v3'), findsNothing);
  expect(find.text('视觉'), findsNWidgets(3));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('草稿：目录事实→行内「视觉」标签；套餐 GLM-5.3 例外；紧跟模型名右侧', (
    tester,
  ) async {
    await _openSheet(
      tester,
      _VisionApp(_widgetView()),
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
    );
    // 套餐组=选中组，默认展开。
    await _expandGroup(tester, _apiPid);
    _expectStandardBadges();
    // 紧跟模型名右侧（桌面端同位），短名/长名各自紧贴而非右对齐一列。
    expectVisionBadgeFollowsModelName(
      tester,
      _row(_planPid, 'glm-5.3-flash'),
      'glm-5.3-flash',
    );
    expectVisionBadgeFollowsModelName(
      tester,
      _row(_apiPid, 'glm-5.3'),
      'glm-5.3',
    );
    // 选中行：标签与 ✓ 并存且不叠压。
    _expectCheckRightOfBadge(tester, _planPid, 'glm-5.3-flash');
    expect(tester.takeException(), isNull);
    await snapWithRealFonts(tester, 'model-vision-composer-light-zh');
  });

  testWidgets('会话内：会话目录不带能力字段，由 getView 目录补齐；白名单语义不变', (
    tester,
  ) async {
    // 前提钉死：会话目录条目本身没有任何能力/接入类型字段。
    final session = _sessionOptions(withHiddenProvider: true);
    expect(session, hasLength(1));
    for (final v in session.first.options) {
      expect(v.toRaw().containsKey('modelSupportsImage'), isFalse);
      expect(v.toRaw().containsKey('modelAccessType'), isFalse);
    }
    await _openSheet(
      tester,
      _VisionApp(
        _widgetView(),
        sessionOptions: _sessionOptions(withHiddenProvider: true),
      ),
      sessionId: 'sess-example',
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
    );
    await _expandGroup(tester, _apiPid);
    _expectStandardBadges();
    expectVisionBadgeFollowsModelName(
      tester,
      _row(_planPid, 'glm-5.3-flash'),
      'glm-5.3-flash',
    );
    _expectCheckRightOfBadge(tester, _planPid, 'glm-5.3-flash');
    // 既有白名单：目录里没有的 provider 仍被丢弃。
    expect(
      _rowOf('account:hidden-plan', 'executor'),
      findsNothing,
      reason: 'hidden 派生 provider 不得随会话目录泄漏进弹层',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话内·目录不可用：不标不崩，会话目录原样可用', (tester) async {
    await _openSheet(
      tester,
      _VisionApp(null, sessionOptions: _sessionOptions()),
      sessionId: 'sess-example',
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
    );
    await _expandGroup(tester, _apiPid);
    expect(find.text('视觉'), findsNothing, reason: '拿不到目录=不猜');
    for (final m in ['glm-5.3', 'glm-5.3-flash', 'glm-5.3-air']) {
      expect(_rowOf(_planPid, m), findsOneWidget);
    }
    for (final m in ['claude-sonnet-4.5', 'glm-5.3', 'deepseek-v3']) {
      expect(_rowOf(_apiPid, m), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('会话内·目录未给事实（模型 config 无 properties）：该型号不标', (
    tester,
  ) async {
    await _openSheet(
      tester,
      _VisionApp(
        _view([
          _provider(
            _planPid,
            name: 'BigModel',
            access: _planAccess(),
            models: [_model('glm-5.3-flash', image: true), _model('glm-5.3')],
          ),
        ]),
        sessionOptions: _sessionOptions(),
      ),
      sessionId: 'sess-example',
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
    );
    expect(_badgeIn(_planPid, 'glm-5.3-flash'), findsOneWidget);
    expect(_badgeIn(_planPid, 'glm-5.3'), findsNothing,
        reason: '目录没给图片能力事实：不标');
  });

  testWidgets('英文界面：标签显示 Vision，无中文残留、无缺译', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    await _openSheet(
      tester,
      _VisionApp(_widgetView()),
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
    );
    await _expandGroup(tester, _apiPid);
    expect(find.text('Vision'), findsNWidgets(3));
    expect(find.text('视觉'), findsNothing);
    expect(L10n.missingTranslations, isEmpty);
    await snapWithRealFonts(tester, 'model-vision-composer-light-en');
  });

  testWidgets('窄屏 320dp + 1.3 字号 + 超长型号：不溢出，模型名省略让位，标签不被裁', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const long =
        'claude-sonnet-4-5-20250929-extended-thinking-with-vision-preview';
    await _openSheet(
      tester,
      _VisionApp(
        _view([
          _provider(
            _apiPid,
            name: 'OCG',
            access: _apiAccess,
            models: [_model(long, image: true), _model('gpt-5.2', image: true)],
          ),
        ]),
      ),
      size: const Size(320, 640),
    );
    final rowFinder = _rowOf(_apiPid, long);
    expect(rowFinder, findsOneWidget);
    expect(tester.getSize(rowFinder).height, greaterThanOrEqualTo(40),
        reason: '行高触控下限不因标签塌陷');
    // 模型名让位：单行省略。
    final name = tester.renderObject<RenderParagraph>(
      find.descendant(of: rowFinder, matching: find.text(long)),
    );
    expect(name.didExceedMaxLines, isTrue, reason: '挤压时模型名省略号让位');
    // 标签恒不收缩：文字按固有宽度完整排布。
    for (var i = 0; i < 2; i++) {
      final badge = tester.renderObject<RenderParagraph>(
        find.text('视觉').at(i),
      );
      expect(
        badge.size.width + 0.5,
        greaterThanOrEqualTo(badge.getMaxIntrinsicWidth(double.infinity)),
        reason: '标签文字不得被裁切',
      );
    }
    expect(tester.takeException(), isNull, reason: '窄屏大字号无溢出');
    await snapWithRealFonts(tester, 'model-vision-composer-light-w320s13');
  });

  // ---- 真字体渲染采集：几何/配色由上方断言钉死，这里
  // 只落盘供目检。字体不可得的机器上这些用例退化为纯断言。

  testWidgets('渲染·深色主题（文字+描边提亮过 AA）', (tester) async {
    await _openSheet(
      tester,
      _VisionApp(_widgetView()),
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
      brightness: Brightness.dark,
    );
    await _expandGroup(tester, _apiPid);
    _expectStandardBadges();
    // 深色提亮断言：文字使用 neutral-300 foreground（#D4D4D4），描边使用 borderHover（15% 白）。
    final badgeFinder = _badgeIn(_planPid, 'glm-5.3-flash');
    final textWidget = tester.widget<Text>(badgeFinder);
    expect(textWidget.style?.color, const Color(0xFFD4D4D4));
    final badgeContainer = tester.widget<Container>(
      find.ancestor(of: badgeFinder, matching: find.byType(Container)).first,
    );
    final border = (badgeContainer.decoration as BoxDecoration).border as Border;
    expect(border.top.color, const Color(0x26FFFFFF));
    await snapWithRealFonts(tester, 'model-vision-composer-dark-zh');
  });

  testWidgets('英文窄屏 320dp + 1.3 字号 + 超长型号：Vision 紧跟模型名且无溢出无缺译', (
    tester,
  ) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    addTearDown(L10n.resetForTest);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const long =
        'claude-sonnet-4-5-20250929-extended-thinking-with-vision-preview';
    await _openSheet(
      tester,
      _VisionApp(
        _view([
          _provider(
            _apiPid,
            name: 'OCG',
            access: _apiAccess,
            models: [_model(long, image: true), _model('glm-5.4', image: true)],
          ),
        ]),
      ),
      pendingModelId: 'glm-5.4',
      pendingModelProvider: _apiPid,
      size: const Size(320, 640),
    );
    expect(find.text('Vision'), findsNWidgets(2));
    expect(L10n.missingTranslations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('渲染·宽屏 840dp（展开态/平板）：标签仍紧跟模型名右侧', (tester) async {
    await _openSheet(
      tester,
      _VisionApp(_widgetView()),
      pendingModelId: 'glm-5.3-flash',
      pendingModelProvider: _planPid,
      size: const Size(840, 900),
    );
    await _expandGroup(tester, _apiPid);
    _expectStandardBadges();
    expectVisionBadgeFollowsModelName(
      tester,
      _row(_planPid, 'glm-5.3-flash'),
      'glm-5.3-flash',
    );
    expectVisionBadgeFollowsModelName(
      tester,
      _row(_apiPid, 'glm-5.3'),
      'glm-5.3',
    );
    expect(tester.takeException(), isNull);
    await snapWithRealFonts(tester, 'model-vision-composer-light-w840');
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final tag = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('渲染·子代理模型分组弹层（$tag）', (tester) async {
      await _usePhoneSize(tester);
      late BuildContext hostContext;
      await tester.pumpWidget(
        _sheetHost(_VisionApp(_widgetView()), brightness, () {
          showSubagentModelSheet(
            hostContext,
            catalog: [
              for (final v in visionCatalogOptions().first.options) v.toRaw(),
            ],
            currentValue: '$_planPid/glm-5.3-flash',
          );
        }),
      );
      hostContext = tester.element(find.byKey(const ValueKey('open')));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester, frames: 8);
      await expectVisionBadgesInSubagentSheet(tester);
      // 选中行：标签与 ✓ 并存且留间距。
      final selected =
          'subagent-model-option-$_planPid/glm-5.3-flash';
      final badgeRight = tester
          .getTopRight(visionBadgeInRow(selected))
          .dx;
      final checkLeft = tester
          .renderObject<RenderBox>(
            find.descendant(
              of: find.byKey(ValueKey(selected)),
              matching: find.byIcon(Icons.check),
            ),
          )
          .localToGlobal(Offset.zero)
          .dx;
      expect(checkLeft - (badgeRight + 5), greaterThanOrEqualTo(5.5));
      expect(tester.takeException(), isNull);
      await snapWithRealFonts(tester, 'model-vision-subagents-$tag-zh');
    });
  }
}
