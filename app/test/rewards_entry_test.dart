import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/rewards_page.dart';
import 'package:zcode_pocket/ui/settings_page.dart';
import 'package:zcode_pocket/ui/web_fallback_page.dart';

/// 奖励中心入口（marketing-claim-1）：URL 构造四档（rewardsEmbedded.ts
/// buildRewardsUrl 对位）、设置页入口可达、页面降级呈现（WebView 通道
/// 缺席）。真实 WebView 加载/登录态/embedded 模式行为留真机验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildRewardsUri（纯函数）', () {
    test('中文浅色=cn/zai-light；embedded=app 恒在', () {
      final uri = buildRewardsUri(dark: false, english: false);
      expect(uri, Uri.parse('https://zcode.z.ai/cn/rewards?embedded=app&theme=zai-light'));
    });

    test('英文深色=en/zai-dark', () {
      final uri = buildRewardsUri(dark: true, english: true);
      expect(uri, Uri.parse('https://zcode.z.ai/en/rewards?embedded=app&theme=zai-dark'));
    });

    test('跨档组合（中文深色/英文浅色）路径与主题参数各自独立', () {
      expect(
        buildRewardsUri(dark: true, english: false).path,
        '/cn/rewards',
      );
      expect(
        buildRewardsUri(dark: true, english: false).queryParameters['theme'],
        'zai-dark',
      );
      expect(
        buildRewardsUri(dark: false, english: true).path,
        '/en/rewards',
      );
    });
  });

  group('review-1：泛化回归与注入桥（审查③中-8/④高2）', () {
    test('WebFallbackPage 默认构造仍指向远控备用页（URL 级断言）', () {
      const page = WebFallbackPage();
      expect(page.initialUri, 'https://zcode.z.ai/remote/v4/');
      expect(page.title, '网页版远控（备用通道）');
      expect(page.navAllowed, same(isWebFallbackNavAllowed));
    });

    test('注入桥：清五键+写当前 JWT/合法 provider+派发官方事件', () {
      final script = buildRewardsSeedScript(
        jwt: 'eyJhbGci.eyJzdWIi.sig',
        provider: 'zai',
        dark: true,
        english: false,
      );
      expect(script, contains("localStorage.removeItem('zcodejwttoken')"));
      expect(
        script,
        contains("localStorage.setItem('zcodejwttoken',\"eyJhbGci.eyJzdWIi.sig\")"),
      );
      expect(script, contains("localStorage.setItem('oauth:active_provider',\"zai\")"));
      expect(script, contains("'zcode-rewards-context'"));
      expect(script, contains('\"status\":\"ready\"'));
      // 前缀防裸奔（官方桥在 try 内执行）。
      expect(script.startsWith('(function(){try{'), isTrue);
    });

    test('注入桥：无 JWT=anonymous；未知 provider 不写键', () {
      final anonymous = buildRewardsSeedScript(
        jwt: null,
        provider: null,
        dark: false,
        english: true,
      );
      expect(anonymous, contains('\"status\":\"anonymous\"'));
      expect(anonymous.contains('setItem'), isFalse);

      final unknownProvider = buildRewardsSeedScript(
        jwt: 'j.w.t',
        provider: 'injected', // 测试 seam 档——非官方枚举
        dark: false,
        english: false,
      );
      expect(unknownProvider, contains("setItem('zcodejwttoken',\"j.w.t\")"));
      expect(
        unknownProvider.contains("setItem('oauth:active_provider'"),
        isFalse,
        reason: '清键照旧，但未知档不写入 provider',
      );
    });
  });

  group('入口与页面（WebView 禁用降级）', () {
    setUp(() => WebFallbackPage.debugDisableWebView = true);
    tearDown(() => WebFallbackPage.debugDisableWebView = false);

    testWidgets('设置页「奖励中心」行可达并推入页面', (tester) async {
      final app = AppState()..loaded = true;
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-rewards-entry')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('奖励中心'), findsOneWidget);
      expect(find.text('官方福利/额度/活动'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-rewards-entry')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(RewardsPage), findsOneWidget);
      // 页面标题 + WebView 通道缺席降级呈现。
      expect(find.text('奖励中心'), findsOneWidget);
      expect(find.textContaining('网页组件不可用'), findsOneWidget);

      await tester.pageBack();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(RewardsPage), findsNothing);
    });

    testWidgets('WebFallbackPage 泛化回归：默认构造仍指向远控备用页',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const WebFallbackPage(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('网页版远控（备用通道）'), findsOneWidget,
          reason: '默认参数= 原行为');
    });
  });
}
