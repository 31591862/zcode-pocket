import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/whats_new.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'pairing_page.dart';
import 'task_center_page.dart';
import 'top_notice.dart';

/// 根入口：无任何档案 → 全屏配对页；有档案 → 任务中心（档案切换在
/// 任务中心顶栏一级入口， 裁决）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// 换页打点只报一次（黑屏取证：bootstrap 首配对瞬间的主线程
  /// 负载定位）。
  bool _announcedSwap = false;

  /// 全新安装静默记录当前版本（防首次配对完进入首页误弹「已更新到 vX.Y.Z」）。
  bool _freshInstallChecked = false;

  void _recordFreshInstallIfNeeded(AppState app) {
    if (_freshInstallChecked || app.suppressWhatsNew) return;
    if (!app.uiPrefs.loaded || app.uiPrefs.lastSeenWhatsNewVersion != null) {
      return;
    }
    _freshInstallChecked = true;
    // 在任何 await 前同步快照初始状态，防止用户在异步窗口内快速登录/配对后
    // 重读已变动的 app.profiles 导致漏记新装。
    final initialFresh = app.freshInstallAtLoad;
    final initialHasProfiles = app.profiles.isNotEmpty;
    unawaited(() async {
      String? versionName;
      try {
        final info = await const MethodChannel(
          'companion/appinfo',
        ).invokeMethod<Map<dynamic, dynamic>>('get');
        final raw = info?['versionName'];
        if (raw is String && raw.trim().isNotEmpty) {
          versionName = raw.trim();
        }
      } catch (_) {
        versionName = null;
      }
      final hasAccount = initialFresh
          ? false
          // 读取异常保守返回 true，绝不把真老用户误吞成新装静默。
          : await app.accountStore.hasAccount.catchError((_) => true);
      if (!mounted) return;
      final action = decideWhatsNewAction(
        appVersion: versionName,
        lastSeenVersion: app.uiPrefs.lastSeenWhatsNewVersion,
        hasExistingSetup:
            !initialFresh && (initialHasProfiles || hasAccount),
      );
      if (action == WhatsNewAction.recordOnly) {
        await app.uiPrefs.setLastSeenWhatsNewVersion(kCurrentWhatsNew.version);
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    TopNotice.attach(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.uiPrefs]),
      builder: (context, _) {
        if (!app.loaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (app.profiles.isEmpty && app.phase == LinkPhase.offline) {
          _announcedSwap = false;
          _recordFreshInstallIfNeeded(app);
          return const PairingPage();
        }
        if (!_announcedSwap) {
          _announcedSwap = true;
          debugPrint('[pairing-perf] home shell -> TaskCenterPage');
        }
        return const TaskCenterPage();
      },
    );
  }
}
