// 外观与语言设置子页（v1.0.10 设置页瘦身）：
// 承接原设置一级页中占屏较高的「主题」与「语言」三档分段选择器，
// 保持原有存储 key、键名（theme-selector / locale-selector / theme-* / locale-*）
// 与即时生效语义不变。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

class SettingsAppearancePage extends StatelessWidget {
  const SettingsAppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('外观与语言', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListenableBuilder(
        listenable: app.uiPrefs,
        builder: (context, _) => ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined, size: 20),
              title: const Text(
                '主题',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '跟随系统或固定浅色/深色',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _SegmentSelector(
                keyValue: 'theme',
                options: const [
                  ('system', '跟随系统'),
                  ('light', '浅色'),
                  ('dark', '深色'),
                ],
                value: app.uiPrefs.themeMode,
                onChanged: (v) => app.uiPrefs.setThemeMode(v),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.language, size: 20),
              title: const Text(
                '语言',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '跟随系统或选择简体中文/English',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _SegmentSelector(
                keyValue: 'locale',
                options: const [
                  ('system', '跟随系统'),
                  ('zh-CN', '中文'),
                  ('en-US', 'English'),
                ],
                value: app.uiPrefs.localePreference,
                onChanged: (v) => app.uiPrefs.setLocalePreference(v),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 三档段选器（自绘 token 化，48dp 触控高，胶囊外形）。
class _SegmentSelector extends StatelessWidget {
  const _SegmentSelector({
    required this.keyValue,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  /// 键前缀（'locale'/'theme'）：容器键 `<keyValue>-selector`、
  /// 分段键 `<keyValue>-<id>`（测试断言依赖既有键名）。
  final String keyValue;

  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('$keyValue-selector'),
      height: 50,
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
      ),
      child: Row(
        children: [
          for (final (id, label) in options)
            Expanded(
              child: GestureDetector(
                key: ValueKey('$keyValue-$id'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(id),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == id
                          ? context.colors.selected
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: value == id
                            ? context.colors.foreground
                            : context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
