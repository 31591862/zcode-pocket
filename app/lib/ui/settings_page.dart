import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'about_page.dart';
import 'device_migration_page.dart';
import 'settings_accounts_page.dart';
import 'settings_security_page.dart';
import 'settings_conversation_page.dart';
import 'settings_notifications_page.dart';
import 'settings_voice_page.dart';
import 'subagents_page.dart';
import 'anchored_menu.dart';
import 'settings_style.dart';
import 'usage_page.dart';

/// 设置页（ 二级化改造，2026-10-20）：一级页只留分组入口——
/// 偏好组（对话/通知/语音输入三入口进二级页）+ 功能组（子智能体/订阅
/// 用量维持原直达跳转）+ 关于组（版本信息内联底部）。各设置项的显示
/// 文案/存储 key/控件行为原样迁入对应二级页，不新增语义。分组头统一用
/// 共享 AppSectionHeader（原私有 _SectionHeader 已删，收敛重复）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ── Eta 风格分组卡（2026-11-16 视觉试点）：样式常量与分组卡/组标签
  // 构建器已抽到 settings_style.dart 共享（下级页同铺，消除"一级新版
  // 二级旧版"割裂）。此处沿用共享实现。
  static const _iconBlue = kSettingsIconBlue;
  static const _iconGreen = kSettingsIconGreen;
  static const _iconOrange = kSettingsIconOrange;

  Widget _groupLabel(BuildContext context, String label) =>
      settingsGroupLabel(context, label);

  Widget _groupCard(BuildContext context, bool isDark, List<Widget> rows) =>
      settingsGroupCard(context, isDark, rows);

  /// 外观（主题/语言）锚定下拉的链接（各一）。
  final _themeMenuLink = LayerLink();
  final _localeMenuLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: settingsPageBg(Theme.of(context).brightness),
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontSize: AppType.uiLg)),
        backgroundColor: settingsPageBg(Theme.of(context).brightness),
      ),
      body: ListenableBuilder(
        listenable: app.uiPrefs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _groupLabel(context, '外观'),
            _groupCard(context, isDark, [
              CompositedTransformTarget(
                link: _themeMenuLink,
                child: Builder(
                  builder: (rowCtx) => ListTile(
                    key: const ValueKey('theme-row'),
                    leading: const Icon(
                      Icons.dark_mode_outlined,
                      size: 24,
                      color: _iconBlue,
                    ),
                    title: const Text(
                      '主题',
                      style: TextStyle(fontSize: AppType.uiBase),
                    ),
                    subtitle: const Text(
                      '跟随系统或固定浅色/深色',
                      style: TextStyle(fontSize: AppType.uiCaption),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          switch (app.uiPrefs.themeMode) {
                            'light' => '浅色',
                            'dark' => '深色',
                            _ => '跟随系统',
                          },
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: context.colors.foregroundSubtle,
                        ),
                      ],
                    ),
                    onTap: () async {
                      final box = rowCtx.findRenderObject()! as RenderBox;
                      final anchorRect =
                          box.localToGlobal(Offset.zero) & box.size;
                      final v = await showAnchoredMenu(
                        context,
                        anchorRect: anchorRect,
                        link: _themeMenuLink,
                        items: [
                          for (final (id, label) in const [
                            ('system', '跟随系统'),
                            ('light', '浅色'),
                            ('dark', '深色'),
                          ])
                            AnchoredMenuItem(
                              value: id,
                              label: label,
                              selected: app.uiPrefs.themeMode == id,
                              key: ValueKey('appearance-theme-$id'),
                            ),
                        ],
                        selectedTextColor: context.colors.brandAccent,
                        highlight: context.colors.brandAccent.withValues(
                          alpha: 0.14,
                        ),
                        maxWidth: 280,
                      );
                      if (v != null) app.uiPrefs.setThemeMode(v);
                    },
                  ),
                ),
              ),
              CompositedTransformTarget(
                link: _localeMenuLink,
                child: Builder(
                  builder: (rowCtx) => ListTile(
                    key: const ValueKey('locale-row'),
                    leading: const Icon(
                      Icons.language,
                      size: 24,
                      color: _iconGreen,
                    ),
                    title: const Text(
                      '语言',
                      style: TextStyle(fontSize: AppType.uiBase),
                    ),
                    subtitle: const Text(
                      '跟随系统或选择简体中文/English',
                      style: TextStyle(fontSize: AppType.uiCaption),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          switch (app.uiPrefs.localePreference) {
                            'zh-CN' => '中文',
                            'en-US' => 'English',
                            _ => '跟随系统',
                          },
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: context.colors.foregroundSubtle,
                        ),
                      ],
                    ),
                    onTap: () async {
                      final box = rowCtx.findRenderObject()! as RenderBox;
                      final anchorRect =
                          box.localToGlobal(Offset.zero) & box.size;
                      final v = await showAnchoredMenu(
                        context,
                        anchorRect: anchorRect,
                        link: _localeMenuLink,
                        items: [
                          for (final (id, label) in const [
                            ('system', '跟随系统'),
                            ('zh-CN', '中文'),
                            ('en-US', 'English'),
                          ])
                            AnchoredMenuItem(
                              value: id,
                              label: label,
                              selected: app.uiPrefs.localePreference == id,
                              key: ValueKey('appearance-locale-$id'),
                            ),
                        ],
                        selectedTextColor: context.colors.brandAccent,
                        highlight: context.colors.brandAccent.withValues(
                          alpha: 0.14,
                        ),
                        maxWidth: 280,
                      );
                      if (v != null) app.uiPrefs.setLocalePreference(v);
                    },
                  ),
                ),
              ),
            ]),
            _groupLabel(context, '偏好'),
            _groupCard(context, isDark, [
              ListTile(
                key: const ValueKey('settings-conversation'),
                leading: const Icon(
                  Icons.forum_outlined,
                  size: 24,
                  color: _iconBlue,
                ),
                title: const Text(
                  '对话与首页',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '对话行为与首页显示（工具活动、新消息处理、其他电脑任务）',
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
                leading: const Icon(
                  Icons.notifications_outlined,
                  size: 24,
                  color: _iconOrange,
                ),
                title: const Text(
                  '通知',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '审批、任务完成等事件的提醒开关与通知台账',
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
                leading: const Icon(
                  Icons.mic_outlined,
                  size: 24,
                  color: _iconGreen,
                ),
                title: const Text(
                  '语音输入',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '听写内容自动整理成规范指令',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsVoicePage()),
                ),
              ),
            ]),
            _groupLabel(context, '功能'),
            _groupCard(context, isDark, [
              ListTile(
                leading: const Icon(
                  Icons.manage_accounts_outlined,
                  size: 24,
                  color: _iconBlue,
                ),
                title: const Text(
                  '账号管理',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '多账号添加/切换/删除（电脑按账号归属连接）',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsAccountsPage(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.smart_toy_outlined,
                  size: 24,
                  color: _iconGreen,
                ),
                title: const Text(
                  '子智能体',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '定义/启停/编辑（与桌面端设置同步）',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SubagentsPage()),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.data_usage_outlined,
                  size: 24,
                  color: _iconBlue,
                ),
                title: const Text(
                  '订阅用量',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '额度/配额/订阅详情',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const UsagePage())),
              ),
            ]),
            _groupLabel(context, '安全'),
            _groupCard(context, isDark, [
              // 应用锁（app-lock-1）：安全组（方式三态/自动锁定/防泄露）。
              ListTile(
                leading: const Icon(
                  Icons.lock_outline,
                  size: 24,
                  color: _iconOrange,
                ),
                title: const Text(
                  '应用锁',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '冷启动与后台锁定需验证（系统锁屏 / PIN 码）',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const SettingsSecurityPage(),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.phone_android,
                  size: 24,
                  color: _iconGreen,
                ),
                title: const Text(
                  '换机助手',
                  style: TextStyle(fontSize: AppType.uiBase),
                ),
                subtitle: const Text(
                  '导出账号与已配对电脑（加密），换手机免重登',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const DeviceMigrationPage(
                      mode: DeviceMigrationMode.export,
                    ),
                  ),
                ),
              ),
            ]),
            _groupLabel(context, '关于'),
            _groupCard(context, isDark, [
              // 关于页（2026-11-04 开源说明聚合批）：声明/隐私/项目许可/
              // 第三方来源/依赖许可集中到二级页，一级页只留一个入口。
              ListTile(
                key: const ValueKey('settings-about'),
                leading: const Icon(
                  Icons.info_outline,
                  size: 24,
                  color: _iconBlue,
                ),
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
            ]),
          ],
        ),
      ),
    );
  }
}

//三档段选器（/ 收敛单源：语言/主题两份逐行
/// 同构实现——触控规格/视觉调整需双改，历史上触控高 46→48 修正两处各
/// 记一遍）。自绘 token 化（官方黑白骨架语言：选中=selected 底+
/// foreground 字，未选=transparent 底+foregroundSubtle 字；48dp 触控高；
/// 胶囊外形）。交互范式参考 zemote 三段式（ 纪律：只参考设计
/// 不移植代码）。
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
          // 缺键/非字符串时显式判 null（原实现
          // '${res['versionName']}' 会把 null 插值成 "null" 字符串通过
          // 非空校验；当前 native 恒填，纯防御）。
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
    return Text(
      local == null
          ? (desktop == null ? '' : tr('桌面端 ') + desktop)
          : tr('本机 ') +
                local +
                (desktop == null ? '' : tr(' · 桌面端 ') + desktop),
      style: const TextStyle(fontSize: AppType.uiCaption),
    );
  }
}
