import 'package:flutter/material.dart';

/// Eta 风格设置页共享样式（2026-11-16 视觉试点，参照 Mangi-11/Eta）：
/// 浅灰底 + 白色无边框圆角卡分组 + 彩色语义图标（蓝/绿/橙三色按类别
/// 编码）+ 组内细分隔线。一级页与全部下级页共用（此前只铺一级页时
/// 点进下级"打回原形"，风格割裂）。
///
/// 纯呈现层约定：路由/按键/回调不在本文件管辖——各页自行保留。
/// 深浅两套色值硬编码（Eta 原样式不走 app 主题 token；主题切换经
/// isDark 分流）。
const Color kSettingsPageBgLight = Color(0xFFF4F5F6);
const Color kSettingsPageBgDark = Color(0xFF151517);
const Color kSettingsCardLight = Colors.white;
const Color kSettingsCardDark = Color(0xFF232427);

/// 蓝/绿/橙语义图标三色：蓝色=信息/导航类，绿色=内容/开关类，
/// 橙色=提醒/安全类（一级页分组时已按此口径铺色，下级页沿用）。
const Color kSettingsIconBlue = Color(0xFF1677FF);
const Color kSettingsIconGreen = Color(0xFF34C759);
const Color kSettingsIconOrange = Color(0xFFFF9500);

/// 页面背景色（含 AppBar 同色——Eta 风格 AppBar 无分隔线，靠分组卡
/// 自身的白底与灰底对比分层）。
Color settingsPageBg(Brightness brightness) =>
    brightness == Brightness.dark ? kSettingsPageBgDark : kSettingsPageBgLight;

/// 组标签：卡外的小号灰字（替代旧 AppSectionHeader 的理工风区块头）。
Widget settingsGroupLabel(BuildContext context, String label) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 16, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0x99EBEBEB)
              : const Color(0x8A262626),
        ),
      ),
    );

/// 分组卡：白色（深色 #232427）无边框圆角 16 容器，行间自动插 54 缩进
/// 细分隔线（对齐 ListTile leading 图标右缘）。
///
/// ListTile 的墨水画在最近的 Material 祖先上——卡容器有底色时必须内套
/// 透明 Material，否则涟漪/高亮被底色遮蔽（Flutter 框架断言）。
Widget settingsGroupCard(
  BuildContext context,
  bool isDark,
  List<Widget> rows,
) {
  final divider = Divider(
    height: 1,
    thickness: 0.5,
    indent: 54,
    color: isDark ? const Color(0x14FFFFFF) : const Color(0x0F000000),
  );
  final children = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    children.add(rows[i]);
    if (i < rows.length - 1) children.add(divider);
  }
  return Container(
    decoration: BoxDecoration(
      color: isDark ? kSettingsCardDark : kSettingsCardLight,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(children: children),
    ),
  );
}
