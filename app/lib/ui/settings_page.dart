import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/l10n.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'about_page.dart';
import 'app_widgets.dart';
import 'settings_accounts_page.dart';
import 'settings_appearance_page.dart';
import 'settings_conversation_page.dart';
import 'settings_notifications_page.dart';
import 'settings_security_page.dart';
import 'settings_voice_page.dart';
import 'subagents_page.dart';
import 'usage_page.dart';

/// 设置页（v1.0.10 四组具象精简结构）：
/// 1. 账号与功能（账号管理 / 子智能体 / 订阅用量）
/// 2. 通用（外观与语言 / 对话与首页 / 通知 / 语音输入）
/// 3. 安全（应用锁）
/// 4. 关于（关于 ZCode Pocket，含检查更新、应用内更新开关与本版更新说明）
///
/// 一级页不再直接摊开大块三段选择器与零散开关，所有入口保持统一行高、
/// 一句话范围预告（让用户未点入即知二级页包含哪些设置）与精简状态摘要。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _appearanceSummary(String themeMode, String localePref) {
    if (themeMode == 'system' && localePref == 'system') {
      return tr('跟随系统');
    }
    final t = switch (themeMode) {
      'light' => tr('浅色'),
      'dark' => tr('深色'),
      _ => tr('跟随系统'),
    };
    final l = switch (localePref) {
      'zh-CN' => tr('中文'),
      'en-US' => 'English',
      _ => tr('跟随系统'),
    };
    return '$t · $l';
  }

  String _appLockSummary(String mode) => switch (mode) {
    'system' => tr('系统锁屏'),
    'pin' => tr('PIN 码'),
    _ => tr('未开启'),
  };

  Widget _trailingWithSummary(BuildContext context, String summary) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              summary,
              translate: false,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([app.uiPrefs, L10n.changes]),
        builder: (context, _) => ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            const AppSectionHeader('账号与功能'),
            ListTile(
              key: const ValueKey('settings-accounts'),
              leading: const Icon(Icons.manage_accounts_outlined, size: 20),
              title: const Text(
                '账号管理',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '多账号登录、备注与切换',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsAccountsPage()),
              ),
            ),
            ListTile(
              key: const ValueKey('settings-subagents'),
              leading: const Icon(Icons.smart_toy_outlined, size: 20),
              title: const Text(
                '子智能体',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '定义、启停与模型覆盖（与桌面端同步）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SubagentsPage())),
            ),
            ListTile(
              key: const ValueKey('settings-usage'),
              leading: const Icon(Icons.data_usage_outlined, size: 20),
              title: const Text(
                '订阅用量',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '套餐剩余额度、历史趋势与用量统计',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const UsagePage())),
            ),
            const AppSectionHeader('通用'),
            ListTile(
              key: const ValueKey('settings-appearance'),
              leading: const Icon(Icons.palette_outlined, size: 20),
              title: const Text(
                '外观与语言',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '深浅主题与界面语言',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: _trailingWithSummary(
                context,
                _appearanceSummary(
                  app.uiPrefs.themeMode,
                  app.uiPrefs.localePreference,
                ),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsAppearancePage(),
                ),
              ),
            ),
            ListTile(
              key: const ValueKey('settings-conversation'),
              leading: const Icon(Icons.forum_outlined, size: 20),
              title: const Text(
                '对话与首页',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '工具调用展示、代码高亮、提问自动采纳与首页多电脑任务',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsConversationPage(),
                ),
              ),
            ),
            ListTile(
              key: const ValueKey('settings-notifications'),
              leading: const Icon(Icons.notifications_outlined, size: 20),
              title: const Text(
                '通知',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '审批、任务完成等后台提醒开关与通知记录',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsNotificationsPage(),
                ),
              ),
            ),
            ListTile(
              key: const ValueKey('settings-voice'),
              leading: const Icon(Icons.mic_outlined, size: 20),
              title: const Text(
                '语音输入',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '语音听写与自动整理指令配置',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsVoicePage()),
              ),
            ),
            const AppSectionHeader('安全'),
            ListTile(
              key: const ValueKey('settings-security'),
              leading: const Icon(Icons.lock_outline, size: 20),
              title: const Text(
                '应用锁',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '冷启动与后台切回验证（系统锁屏 / PIN）、防截屏',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: _trailingWithSummary(
                context,
                _appLockSummary(app.uiPrefs.appLockModeRaw),
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsSecurityPage()),
              ),
            ),
            const AppSectionHeader('关于'),
            ListTile(
              key: const ValueKey('settings-about'),
              leading: const Icon(Icons.info_outline, size: 20),
              title: const Text(
                '关于 ZCode Pocket',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const _AppVersionText(),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AboutZcodePocketPage(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 关于行副标题：本机版本（release 含 HEAD 指纹）+ 桌面端版本 + 范围提示。
class _AppVersionText extends StatefulWidget {
  const _AppVersionText();

  @override
  State<_AppVersionText> createState() => _AppVersionTextState();
}

class _AppVersionTextState extends State<_AppVersionText> {
  String? _localVersion;

  @override
  void initState() {
    super.initState();
    const MethodChannel('companion/appinfo')
        .invokeMethod<Map>('get')
        .then((res) {
          final raw = res?['versionName'];
          final name = raw is String && raw.trim().isNotEmpty ? raw : null;
          if (mounted && name != null) {
            setState(() => _localVersion = name);
          }
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final desktop = AppStateScope.of(context).desktopAppVersion;
    final local = _localVersion;
    return ListenableBuilder(
      listenable: L10n.changes,
      builder: (context, _) {
        final ver = local == null
            ? (desktop == null ? '' : tr('桌面端 ') + desktop)
            : tr('本机 ') +
                  local +
                  (desktop == null ? '' : tr(' · 桌面端 ') + desktop);
        return Text(
          ver.isEmpty ? tr('软件更新、更新说明、清除缓存与开源许可') : ver,
          translate: false,
          style: const TextStyle(fontSize: AppType.uiCaption),
        );
      },
    );
  }
}
