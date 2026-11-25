// 小窗异常顶部 padding 根层守卫（2026-11-25）：部分 ROM 的小窗把约等于
// 窗口高的值报成顶部安全区，Flutter 页面整体被推出可视区，只剩悬浮按钮
// （上游 flutter/flutter#161086，引擎未修）。
//
// 红=无守卫时输入栏落在可视区外；绿=守卫钳制后回到可视区。另钉：守卫
// 跟随原生顶栏高度、正常状态零变化、应用根 builder 确实挂了守卫。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/core/system_inset.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/pairing_page.dart';

const _w = 390.0;
const _h = 844.0;
// 小窗异常形态：顶部 padding≈窗口高（只差一条状态栏）。
const _abnormalTop = 820.0;

void _setWindow(WidgetTester tester, {required double topPadding}) {
  tester.view.physicalSize = const Size(_w, _h);
  tester.view.devicePixelRatio = 1.0;
  final pad = FakeViewPadding(top: topPadding);
  tester.view.padding = pad;
  tester.view.viewPadding = pad;
  addTearDown(tester.view.reset);
}

/// 与应用根 builder 同构的宿主：守卫可选，用来对照有无守卫的差异。
Widget _pageHost({required bool guard}) => AppStateScope(
      app: AppState(),
      child: MaterialApp(
        builder: guard
            ? (context, child) =>
                FreeformTopPaddingGuard(child: child ?? const SizedBox.shrink())
            : null,
        home: const Scaffold(
          body: ConversationPage(sessionId: null, title: '草稿'),
        ),
      ),
    );

Finder get _composer => find.byKey(const ValueKey('chat-input'));

void main() {
  setUp(() => systemCaptionTopDp.value = 0);
  tearDown(() => systemCaptionTopDp.value = 0);

  testWidgets('红：无守卫时异常顶部 padding 把输入栏推出可视区', (tester) async {
    _setWindow(tester, topPadding: _abnormalTop);
    await tester.pumpWidget(_pageHost(guard: false));
    await tester.pump();
    final rect = tester.getRect(_composer);
    expect(rect.bottom, greaterThan(_h),
        reason: '输入栏整体落在窗口之外——用户所见即整页空白');
  });

  testWidgets('绿：守卫钳制后输入栏留在可视区，高度不变', (tester) async {
    // 先在正常状态下量一次输入栏，作为对照。
    _setWindow(tester, topPadding: 24);
    await tester.pumpWidget(_pageHost(guard: true));
    await tester.pump();
    final normal = tester.getRect(_composer);

    // 进入小窗：metrics 突变为异常顶部 padding（原生顶栏高度尚未推送）。
    final abnormal = const FakeViewPadding(top: _abnormalTop);
    tester.view.padding = abnormal;
    tester.view.viewPadding = abnormal;
    await tester.pump();
    await tester.pump();
    final rect = tester.getRect(_composer);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(_h));
    expect(rect.height, normal.height, reason: '钳制只挪位置，不改尺寸');
  });

  testWidgets('守卫跟随原生顶栏高度：推送到达后钳制目标更新', (tester) async {
    _setWindow(tester, topPadding: _abnormalTop);
    await tester.pumpWidget(_pageHost(guard: true));
    await tester.pump();
    MediaQueryData mq() =>
        MediaQuery.of(tester.element(find.byType(ConversationPage)));
    expect(mq().padding.top, 0, reason: '顶栏高度未推送时钳到 0');

    systemCaptionTopDp.value = 40;
    await tester.pump();
    expect(mq().padding.top, 40);
    expect(mq().viewPadding.top, 40, reason: 'padding 与 viewPadding 同钳');
  });

  testWidgets('正常状态零变化：普通状态栏高度原样透传', (tester) async {
    _setWindow(tester, topPadding: 24);
    await tester.pumpWidget(_pageHost(guard: true));
    await tester.pump();
    // 即使顶栏值很大，顶部 padding 正常就一律不动。
    systemCaptionTopDp.value = 60;
    await tester.pump();
    final mq = MediaQuery.of(tester.element(find.byType(ConversationPage)));
    expect(mq.padding.top, 24);
    expect(mq.viewPadding.top, 24);
  });

  testWidgets('根 builder 接线：应用在异常 padding 下钳制且守卫在位', (tester) async {
    final app = AppState()..loaded = true;
    app.uiPrefs.debugMarkLoadedForTest();
    _setWindow(tester, topPadding: _abnormalTop);
    await tester.pumpWidget(ZcodeCompanionApp(app: app));
    await tester.pump();
    expect(find.byType(FreeformTopPaddingGuard), findsOneWidget);
    final mq = MediaQuery.of(tester.element(find.byType(PairingPage)));
    expect(mq.padding.top, 0);
    expect(mq.size.height, _h, reason: '只钳 padding，窗口尺寸不动');
    app.dispose();
  });
}
