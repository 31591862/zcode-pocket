// 模型「视觉」能力标签（官方桌面 ModelConfigSelect 行内徽标对位）。
//
// 规则真源=官方 modelVisionBadge.ts shouldShowModelVisionBadge（逐句对位，
// 不自行加减）：
//   1. 仅 supportsImage === true 才可能显示；
//   2. 展示例外：套餐接入（zhipu-coding-plan-api-key，或 zhipu-account 的
//      individual-coding-plan / team-coding-plan / start-plan）下的
//      glm-5.3 不标——其图片输入是服务端桥接，不能标成原生视觉；
//   3. 只控制标签，不改能力事实/附件校验。
// 观感真源=官方 ModelInputCapabilityBadge：描边胶囊 + surface 底 +
// foreground-subtle 小字。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';

/// 目录条目是否显示「视觉」标签。
///
/// [modelId]=注册表模型 ID（不含 provider 前缀）；[supportsImage]=目录
/// 事实（null=目录未给，不标）；[accessType]/[accessMode]=供应商
/// config.access 的 type/mode。
bool shouldShowModelVisionBadge(
  String modelId,
  bool? supportsImage, {
  String? accessType,
  String? accessMode,
}) {
  if (supportsImage != true) return false;
  const planAccountModes = {
    'individual-coding-plan',
    'team-coding-plan',
    'start-plan',
  };
  final planAccess =
      accessType == 'zhipu-coding-plan-api-key' ||
      (accessType == 'zhipu-account' && planAccountModes.contains(accessMode));
  return !(planAccess && modelId.toLowerCase() == 'glm-5.3');
}

/// 「视觉」小标签。纯展示（不可点、不参与行内伸缩——恒按自身宽度
/// 排布，挤压时由模型名省略号让位）。
class ModelVisionBadge extends StatelessWidget {
  const ModelVisionBadge({super.key});

  /// 官方 i18n 键 model.capability.vision（zh-CN「视觉」/ en-US
  /// 「Vision」）；本仓官方词表已收录，英文界面零缺译。
  static const label = '视觉';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色提亮：深色选中行底色提亮后，
    // foregroundSubtle(60%) 在胶囊底上仅 3.22:1 且 10% 描边溶入背景；
    // 深色改用 foreground(neutral-300) + borderHover(15% 白)，选中/未选中
    // 均过小字 AA 线；浅色保持官方同档（5.1–5.3:1）。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: isDark ? c.borderHover : c.border),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: AppType.uiXs,
          fontWeight: FontWeight.w500,
          color: isDark ? c.foreground : c.foregroundSubtle,
        ),
      ),
    );
  }
}
