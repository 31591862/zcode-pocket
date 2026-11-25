/// 版本更新说明（What's New）数据与触发判定（v1.0.10 起）：
///
/// 原则：
/// 1. 仅随包内置**当前版本**的亮点内容与精选 WebP 截图（仅对视觉/交互变化显著的项
///    配图，纯规则/文字即可说清的项不强行塞图，保持安装包轻量化、离线秒开、零外网请求）。
/// 2. 触发纪律：
///    - 仅当安装包 SemVer 与 [kCurrentWhatsNew.version] 精确一致时启用（开发期构建
///      或旧说明不误弹）；
///    - 全新安装（本地无已配对电脑且无已读记录）静默记已读、不打断首次配对；
///    - 从旧版本升级的老用户（已有电脑/账号或已读版本不同）进入任务主页时弹一次，
///      关闭后持久化 `ui.lastSeenWhatsNewVersion`，后续不再重复弹出；
///    - 随时可在「设置 → 关于 → 本版更新说明」回看。
library;

/// 单条版本更新亮点（[lightImageAsset]/[darkImageAsset] 为空时仅展示文字）。
class WhatsNewHighlight {
  const WhatsNewHighlight({
    required this.iconName,
    required this.title,
    required this.description,
    this.lightImageAsset,
    this.darkImageAsset,
  });

  /// 图标语义键（'usage' | 'workflow' | 'vision' | 'order' | 'settings' | 'window'）。
  final String iconName;
  final String title;
  final String description;
  final String? lightImageAsset;
  final String? darkImageAsset;

  bool get hasScreenshot =>
      (lightImageAsset != null && lightImageAsset!.isNotEmpty) ||
      (darkImageAsset != null && darkImageAsset!.isNotEmpty);

  String? assetForBrightness({required bool isDark}) =>
      isDark ? (darkImageAsset ?? lightImageAsset) : (lightImageAsset ?? darkImageAsset);
}

/// 单个版本的更新说明定义。
class WhatsNewRelease {
  const WhatsNewRelease({
    required this.version,
    required this.headline,
    required this.highlights,
  });

  /// 规范 SemVer（如 '1.0.10'），与打包版本主版本号比对。
  final String version;
  final String headline;
  final List<WhatsNewHighlight> highlights;
}

/// 当前随包发布的版本更新说明（发下一版时替换为新版本内容与精选截图）。
const WhatsNewRelease kCurrentWhatsNew = WhatsNewRelease(
  version: '1.0.10',
  headline: '首页用量速览、已保存工作流一键启动与设置页精简',
  highlights: [
    WhatsNewHighlight(
      iconName: 'usage',
      title: '首页「用量速览」与多账号聚合',
      description:
          '首页顶栏新增用量速览，同屏查看官方 GLM Coding Plan、激活态 Start Plan 福利包（桌面离线也可直连查看）与多账号缓存；点右上角 + 可自定义排序、显隐，并按需添加外部套餐额度查询（支持 Kimi Coding、OpenCode Go、GLM Coding Plan 直连、小米 MiMo Token Plan、Ollama Cloud、Command Code，查询方式与开源工具 cc-switch 的实现同类；仅查剩余额度，订阅与模型配置请在桌面端完成）。',
      lightImageAsset: 'assets/whats_new/usage_quick_light.webp',
      darkImageAsset: 'assets/whats_new/usage_quick_dark.webp',
    ),
    WhatsNewHighlight(
      iconName: 'workflow',
      title: '已保存工作流一键启动',
      description:
          '任务主页右上角菜单新增「已保存工作流」，按当前项目与全局分类浏览，支持无参一键运行或填写参数校验后直接启动。',
      lightImageAsset: 'assets/whats_new/saved_workflows_light.webp',
      darkImageAsset: 'assets/whats_new/saved_workflows_dark.webp',
    ),
    WhatsNewHighlight(
      iconName: 'vision',
      title: '模型「视觉」标签对齐桌面与工作流分组',
      description:
          '四处模型选择弹层的「视觉」标签紧跟模型名称右侧并提亮深色对比度；工作流模型列表支持按提供方/套餐折叠分组。',
    ),
    WhatsNewHighlight(
      iconName: 'order',
      title: '项目顺序默认跟随桌面端',
      description:
          '主页项目默认同步桌面侧栏拖动顺序，仍保留本机拖动微调与「恢复跟随桌面」一键复位。',
    ),
    WhatsNewHighlight(
      iconName: 'settings',
      title: '设置页结构精简',
      description:
          '重组为「账号与功能 / 通用 / 安全 / 关于」四组清晰入口，外观与语言、更新开关收进二级页，一屏直达不杂乱。',
    ),
    WhatsNewHighlight(
      iconName: 'window',
      title: '小窗模式白屏修复',
      description:
          '部分机型把应用挂到系统小窗后整页空白、只剩悬浮按钮；现已修正被错误放大的顶部安全区，小窗内可正常使用。',
    ),
  ],
);

/// 从 `versionName` 提取规范 `MAJOR.MINOR.PATCH`（如 `1.0.10-abc123` → `1.0.10`）；
/// 0.x 开发占位版或非法字符串返回 null。
String? normalizeReleaseSemver(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^v?(\d+\.\d+\.\d+)(?:[-+].*)?$').firstMatch(trimmed);
  if (match == null) return null;
  final semver = match.group(1)!;
  if (semver.startsWith('0.')) return null;
  return semver;
}

/// 首页检查更新说明后的动作决策。
enum WhatsNewAction {
  /// 不弹窗、不写存储（版本不匹配或已看过）。
  none,

  /// 全新安装：静默记录当前版本号，不打断首次配对流程。
  recordOnly,

  /// 老用户升级：弹出本版更新说明，关闭后记录已读。
  showPopup,
}

/// 判定进入首页后是否弹出版本更新说明（纯函数，供单测直接覆盖所有边界）。
WhatsNewAction decideWhatsNewAction({
  required String? appVersion,
  required String? lastSeenVersion,
  required bool hasExistingSetup,
  WhatsNewRelease release = kCurrentWhatsNew,
}) {
  final current = normalizeReleaseSemver(appVersion);
  if (current == null || current != release.version) {
    return WhatsNewAction.none;
  }
  final seen = normalizeReleaseSemver(lastSeenVersion);
  if (seen == current) {
    return WhatsNewAction.none;
  }
  if (seen == null && !hasExistingSetup) {
    return WhatsNewAction.recordOnly;
  }
  return WhatsNewAction.showPopup;
}
