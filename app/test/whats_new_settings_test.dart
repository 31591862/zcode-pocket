// v1.0.10 设置页瘦身（四组具象结构）+ 版本更新后首页「更新说明（精选截图）」弹层测试：
// - normalizeReleaseSemver / decideWhatsNewAction 全边界（新装静默、升级首弹、已读不弹、开发版不弹）
// - UiPrefs.lastSeenWhatsNewVersion 持久化往返
// - fork SettingsPage 分组结构（外观行锚定下拉）+ SettingsConversationPage + AboutZcodePocketPage
// - TaskCenterPage 升级自动弹出一次（含应用锁解开后才弹）、新装静默不打扰、点击预览大图与 EN 320dp 零溢出
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/core/whats_new.dart';
import 'package:zcode_pocket/demo/demo_app_state.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/about_page.dart';
import 'package:zcode_pocket/ui/home_shell.dart';
import 'package:zcode_pocket/ui/settings_conversation_page.dart';
import 'package:zcode_pocket/ui/settings_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';
import 'package:zcode_pocket/ui/whats_new_sheet.dart';

import 'real_font_snapshot.dart';

class _MemSecureStorage extends FlutterSecureStorage {
  _MemSecureStorage()
    : super(
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  final Map<String, String> data = {};

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
    data.remove(key);
  }
}

class _TestApp extends AppState {
  _TestApp(this._prefs, {super.accountStore});
  final UiPrefs _prefs;

  @override
  UiPrefs get uiPrefs => _prefs;
}

void main() {
  group('WhatsNew 纯逻辑与持久化', () {
    test('normalizeReleaseSemver 解析正式版与忽略开发占位版', () {
      expect(normalizeReleaseSemver('1.0.10'), '1.0.10');
      expect(normalizeReleaseSemver('1.0.10-415bfa3e6490'), '1.0.10');
      expect(normalizeReleaseSemver('v1.0.10+2026112501'), '1.0.10');
      expect(normalizeReleaseSemver('0.1.0-abc123'), isNull);
      expect(normalizeReleaseSemver(''), isNull);
      expect(normalizeReleaseSemver(null), isNull);
    });

    test('decideWhatsNewAction：新装静默、升级首弹、已读不弹、版本不匹配不弹', () {
      // 全新安装（无电脑无账号无历史记录）→ 静默记录，不打断配对
      expect(
        decideWhatsNewAction(
          appVersion: '1.0.10-abcdef',
          lastSeenVersion: null,
          hasExistingSetup: false,
        ),
        WhatsNewAction.recordOnly,
      );
      // 从旧版（无字段但已有配对电脑/账号）升级 → 弹一次
      expect(
        decideWhatsNewAction(
          appVersion: '1.0.10-abcdef',
          lastSeenVersion: null,
          hasExistingSetup: true,
        ),
        WhatsNewAction.showPopup,
      );
      // 从旧版本记录升级 → 弹一次
      expect(
        decideWhatsNewAction(
          appVersion: '1.0.10',
          lastSeenVersion: '1.0.9',
          hasExistingSetup: false,
        ),
        WhatsNewAction.showPopup,
      );
      // 已看过本版 → 不再弹
      expect(
        decideWhatsNewAction(
          appVersion: '1.0.10-abcdef',
          lastSeenVersion: '1.0.10',
          hasExistingSetup: true,
        ),
        WhatsNewAction.none,
      );
      // 开发占位或旧包 → 不弹
      expect(
        decideWhatsNewAction(
          appVersion: '0.1.0-dev',
          lastSeenVersion: null,
          hasExistingSetup: true,
        ),
        WhatsNewAction.none,
      );
      expect(
        decideWhatsNewAction(
          appVersion: '1.0.9',
          lastSeenVersion: null,
          hasExistingSetup: true,
        ),
        WhatsNewAction.none,
      );
    });

    test('UiPrefs.lastSeenWhatsNewVersion 持久化往返', () async {
      final storage = _MemSecureStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();
      expect(prefs.lastSeenWhatsNewVersion, isNull);
      await prefs.setLastSeenWhatsNewVersion('1.0.10');
      expect(prefs.lastSeenWhatsNewVersion, '1.0.10');

      final reloaded = UiPrefs(storage: storage);
      await reloaded.load();
      expect(reloaded.lastSeenWhatsNewVersion, '1.0.10');
    });

    test('kCurrentWhatsNew 仅重点项配图（2 项带浅深图，4 项纯文字，含小窗修复）', () {
      expect(kCurrentWhatsNew.version, '1.0.10');
      final withShots = kCurrentWhatsNew.highlights
          .where((h) => h.hasScreenshot)
          .toList();
      final textOnly = kCurrentWhatsNew.highlights
          .where((h) => !h.hasScreenshot)
          .toList();
      expect(withShots, hasLength(2));
      expect(textOnly, hasLength(4));
      // 用户可见的缺陷修复也要进更新说明，不能只有新功能。
      expect(
        textOnly.map((h) => h.title),
        contains('小窗模式白屏修复'),
      );
      for (final item in withShots) {
        expect(item.lightImageAsset, endsWith('.webp'));
        expect(item.darkImageAsset, endsWith('.webp'));
      }
    });
  });

  group('设置页瘦身与更新说明交互旅程', () {
    testWidgets('SettingsPage 四组具象精简结构 + 二级页完整可达 + 320dp/1.3x/EN 零溢出零缺译', (
      tester,
    ) async {
      final storage = _MemSecureStorage();
      final prefs = UiPrefs(storage: storage);
      await prefs.load();
      final app = _TestApp(prefs)..loaded = true;

      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // fork 分组结构（外观/偏好/功能/安全/关于）：无大块三段选择器
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('偏好'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('关于'), 200);
      expect(find.text('安全'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('外观'), -200);
      expect(find.byKey(const ValueKey('theme-selector')), findsNothing);
      expect(find.byKey(const ValueKey('locale-selector')), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-show-other-computers')),
        findsNothing,
      );

      // fork 语义（用户拍板）：主题/语言为一级页锚定下拉行，无外观二级页
      expect(find.byKey(const ValueKey('theme-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('locale-row')), findsOneWidget);

      // 进「对话与首页」二级页，包含原「首页显示其他电脑任务」开关
      await tester.tap(find.byKey(const ValueKey('settings-conversation')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsConversationPage), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-show-other-computers')),
        200,
      );
      expect(
        find.byKey(const ValueKey('settings-show-other-computers')),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byType(SettingsConversationPage))).pop();
      await tester.pumpAndSettle();

      // 进「关于」页，可随时打开「本版更新说明」并点击预览大图
      final aboutTile = find.byKey(const ValueKey('settings-about'));
      await tester.scrollUntilVisible(aboutTile, 200);
      await tester.ensureVisible(aboutTile);
      await tester.pumpAndSettle();
      await tester.tap(aboutTile);
      await tester.pumpAndSettle();
      expect(find.byType(AboutZcodePocketPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('about-whats-new')));
      await tester.pumpAndSettle();
      expect(find.byType(WhatsNewSheet), findsOneWidget);
      expect(find.text('已更新到 v1.0.10'), findsOneWidget);
      expect(find.byKey(const ValueKey('whats-new-shot-0')), findsOneWidget);

      // 点击截图卡片打开大图预览并关闭
      await tester.tap(find.byKey(const ValueKey('whats-new-shot-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('whats-new-preview-close')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('whats-new-preview-close')));
      await tester.pumpAndSettle();

      // 切 EN + 320dp + 1.3x 校验 WhatsNewSheet 与 SettingsPage 零溢出零缺译
      L10n.setTestLocale('en-US');
      L10n.collectMissing = true;
      addTearDown(L10n.resetForTest);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpAndSettle();
      expect(find.text('Updated to v1.0.10'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);

      // 关闭更新说明 + 返回设置一级页，再次校验 EN 零溢出零缺译
      await tester.tap(find.byKey(const ValueKey('whats-new-confirm')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(AboutZcodePocketPage))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Appearance'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Appearance'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Preferences'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Preferences'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(L10n.missingTranslations, isEmpty);
    });

    testWidgets('TaskCenterPage：老用户升级自动弹一次更新说明，关闭后记已读不再重复；全新安装静默不弹', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/appinfo'),
        (_) async => {'versionName': '1.0.10-abcdef12'},
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/appinfo'),
          null,
        );
      });

      // 1) 老用户升级（已有配对电脑）：进入首页自动弹出一次
      final storage1 = _MemSecureStorage();
      final prefs1 = UiPrefs(storage: storage1);
      await prefs1.load();
      final app1 = _TestApp(
        prefs1,
        accountStore: AccountStore(storage: storage1),
      )..loaded = true;
      app1.profiles = [
        AccountV2Profile(
          deviceSid: 'sid-1',
          deviceName: 'MacBook',
          label: 'MacBook',
          addedAt: DateTime(2026, 11, 20),
          accountId: 'acc-1',
        ),
      ];

      await tester.pumpWidget(
        AppStateScope(
          app: app1,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const TaskCenterPage(),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(WhatsNewSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('whats-new-confirm')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(WhatsNewSheet), findsNothing);
      expect(prefs1.lastSeenWhatsNewVersion, '1.0.10');

      // 2) 重建首页：已读同版本绝不再弹
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        AppStateScope(
          app: app1,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const TaskCenterPage(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(WhatsNewSheet), findsNothing);

      // 3) 全新安装经 HomeShell（PairingPage → 首次配对后进 TaskCenterPage）：
      //    在 PairingPage 阶段即静默记录版本，配对完成后进入首页绝不误弹更新说明。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final storage2 = _MemSecureStorage();
      final prefs2 = UiPrefs(storage: storage2);
      await prefs2.load();
      final app2 = _TestApp(
        prefs2,
        accountStore: AccountStore(storage: storage2),
      )..loaded = true;
      await tester.pumpWidget(
        AppStateScope(
          app: app2,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const HomeShell(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(prefs2.lastSeenWhatsNewVersion, '1.0.10');
      expect(find.byType(WhatsNewSheet), findsNothing);

      // 模拟首次配对完成切入 TaskCenterPage：不得弹出更新说明
      app2.profiles = [
        AccountV2Profile(
          deviceSid: 'sid-new',
          deviceName: 'FirstPC',
          label: 'FirstPC',
          addedAt: DateTime(2026, 11, 25),
          accountId: 'acc-new',
        ),
      ];
      app2.notifyListeners();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(TaskCenterPage), findsOneWidget);
      expect(find.byType(WhatsNewSheet), findsNothing);
    });
  });

  group('真字体渲染采集：精简设置页与版本更新说明（浅/深）', () {
    setUpAll(loadRealFonts);
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final tag = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('渲染·精简设置页与更新说明弹层（$tag）', (tester) async {
        tester.view.physicalSize = const Size(375, 806);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final prefs = UiPrefs(storage: _MemSecureStorage());
        await prefs.load();
        final app = _TestApp(prefs)..loaded = true;

        await tester.pumpWidget(
          RepaintBoundary(
            key: realFontShotKey,
            child: AppStateScope(
              app: app,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: reviewTheme(brightness),
                home: const SettingsPage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'settings-slim-$tag-zh');

        // 采集版本更新说明弹层（带精选 WebP 截图）
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
                        key: const ValueKey('open-wn'),
                        onPressed: () => showWhatsNewSheet(ctx),
                        icon: const Icon(Icons.auto_awesome),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-wn')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          for (final h in kCurrentWhatsNew.highlights) {
            final a = h.assetForBrightness(
              isDark: brightness == Brightness.dark,
            );
            if (a != null) {
              await precacheImage(AssetImage(a), ctx);
            }
          }
        });
        await tester.pumpAndSettle();
        expect(find.byType(WhatsNewSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await snapWithRealFonts(tester, 'whats-new-$tag-zh');
      });
    }
  });

  group('回归：DemoAppState 抑制与隔离 / AboutPage 无 Scope / SettingsPage 热切系统语言', () {
    testWidgets('DemoAppState 在非 ZP_DEMO 环境下抑制更新说明且绝不触碰真实存储', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({'real_secret_sentinel': 'keep'});
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('companion/appinfo'),
        (_) async => {'versionName': '1.0.10-abcdef12'},
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('companion/appinfo'),
          null,
        );
      });

      final demo = DemoAppState();
      expect(demo.suppressWhatsNew, isTrue);
      expect(await demo.accountStore.listAccounts(), isEmpty);

      await tester.pumpWidget(
        AppStateScope(
          app: demo,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const TaskCenterPage(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(WhatsNewSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      demo.dispose();
    });

    testWidgets('AboutZcodePocketPage 无 AppStateScope 时隐藏清除缓存且不崩；SettingsPage 随 L10n.changes 即时刷新摘要', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const AboutZcodePocketPage(versionOverride: '1.0.10'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('about-clear-cache')), findsNothing);
      expect(find.byKey(const ValueKey('about-whats-new')), findsOneWidget);

      final prefs = UiPrefs(storage: _MemSecureStorage());
      await prefs.load();
      final app = _TestApp(prefs)..loaded = true;
      L10n.setTestLocale('zh-CN');
      addTearDown(L10n.resetForTest);

      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: MaterialApp(
            theme: buildAppTheme(Brightness.light),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // fork 一级页主题/语言两行摘要均为「跟随系统」（上游外观二级页只有
      // 语言一行）。
      expect(find.text('跟随系统'), findsNWidgets(2));

      // 模拟「跟随系统」档下系统语言切英文：无需改动 uiPrefs，右侧摘要必须同步刷新。
      L10n.setTestLocale('en-US');
      await tester.pumpAndSettle();
      expect(find.text('System'), findsNWidgets(2));
      expect(find.text('跟随系统'), findsNothing);
    });
  });
}
