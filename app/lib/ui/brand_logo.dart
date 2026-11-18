import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 模型品牌 → 官方 logo 矢量资产映射（Paseo 参考批，2026-10-23 用户
/// 拍板："用真实的 logo，不要程序手绘"）。
///
/// 资产来源（assets/brand_logos/，全部为品牌官方图形的忠实单色转写，
/// path 数据原样保留，仅统一无填充由运行时染色）：
/// - anthropic/gemini/deepseek/moonshotai/qwen：Simple Icons 官方 path
///   （品牌官方标志的单色矢量转写，CC0）。
/// - openai/mistralai/meta：Simple Icons 同源同工艺补齐（2026-10-24
/// 修复批 拍板）。
/// - x/xiaomi/minimax/nvidia：Simple Icons 同源同工艺补齐（2026-11-05
///   反馈④"各模型 logo 充分补齐"——xAI 的 X 形标已被收录（slug=x，与
///   xAI 官方同形）；OCG 常见第三方品牌覆盖 mimo/minimax/nemotron。
///   stepfun/volcengine(doubao)/tencent(hunyuan) 仍未被收录，保持
///   中性点回退，收录后再补）。
/// - zhipu：Z.ai 官方 CDN（z-cdn.chatglm.cn/z-ai/static/logo.svg）的
///   Z 字标三形状（原 path 数据，去底板/描边单色化）。
/// 渲染时 colorFilter 染当前文字色——不引入彩色（"彩色仅点睛"定调）。
/// 缺失品牌返回 null 回退纯文字，不留空位。
String? brandLogoAsset(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('glm') ||
      id.contains('zhipu') ||
      id.contains('chatglm') ||
      // 智谱系非 GLM 命名模型（2026-11-05 反馈④：codegeex/charglm/
      // emohaa 落 dot 的漏网归并）。
      id.contains('codegeex') ||
      id.contains('charglm') ||
      id.contains('emohaa')) {
    return 'assets/brand_logos/zhipu.svg';
  }
  if (id.contains('claude')) return 'assets/brand_logos/claude.svg';
  if (id.contains('gemini')) return 'assets/brand_logos/googlegemini.svg';
  if (id.contains('deepseek')) return 'assets/brand_logos/deepseek.svg';
  // 小米 MiMo（2026-11-05 反馈④用户点名）：官方 provider 图标即小米标。
  if (id.contains('mimo') || id.contains('xiaomi')) {
    return 'assets/brand_logos/xiaomi.svg';
  }
  if (id.contains('minimax')) return 'assets/brand_logos/minimax.svg';
  // xAI Grok：X 形标（Simple Icons slug=x，与 xAI 官方同形）。
  if (id.contains('grok') || id.contains('x-ai')) {
    return 'assets/brand_logos/x.svg';
  }
  if (id.contains('nemotron') || id.contains('nvidia')) {
    return 'assets/brand_logos/nvidia.svg';
  }
  if (id.contains('kimi') ||
      id.contains('moonshot') ||
      // Kimi K 系新档 id 不带 kimi 字样（k3.1-pro，2026-10-25 真机实锤）
      // ——k+数字须词边界（grok-3 的 k 前是字母，不命中）。
      // 2026-10-26 真机验收①：moonshotai.svg=公司标被用户判错——官方
      // 桌面用 Kimi 品牌标（refs ProviderLogo.tsx:12 moonshot-kimi 资产）
      // → 换 Simple Icons kimi 官方标（同源同工艺）。
      RegExp(r'(^|[^a-z0-9])k\d').hasMatch(id)) {
    return 'assets/brand_logos/kimi.svg';
  }
  if (id.contains('qwen') || id.contains('qwq')) {
    return 'assets/brand_logos/qwen.svg';
  }
  if (id.contains('openai') ||
      id.contains('gpt') ||
      // o1/o3/o4 系需词边界（裸 contains('o1') 会误吞任何含 o1 的 id）。
      RegExp(r'(^|[^a-z0-9])o[134]($|[^a-z0-9])').hasMatch(id)) {
    return 'assets/brand_logos/openai.svg';
  }
  if (id.contains('mistral') ||
      id.contains('ministral') ||
      id.contains('codestral') ||
      id.contains('magistral') ||
      id.contains('devstral')) {
    return 'assets/brand_logos/mistralai.svg';
  }
  if (id.contains('llama')) return 'assets/brand_logos/meta.svg';
  return null;
}

/// 品牌色表（2026-10-26 用户拍板①：浅色模式上品牌原色——黑白跟随文字
/// 色只服务深色可见度，浅色沿用同一逻辑属配色走样）。
/// 来源与勘误（2026-10-26 用户复核纠偏：**模型/产品品牌色≠公司品牌色**，
/// 且以官方桌面 provider 图标实测为最高锚点）：
/// - deepseek 4D6BFE：官方图标实测蓝（provider-icons PNG 主色）✔；
/// - qwen 615CED / gemini 8E75B2 / mistral FF7000 / claude D97757：
///   产品品牌色（SI 产品条目/用户拍板）✔；
/// - **智谱（glm/zhipu）与 OpenAI（gpt/o 系）不入表**：官方桌面三枚
///   智谱系图标全为单色标（zai/zai-app 黑、bigmodel 白——实测 PNG/SVG
///   填色），OpenAI 官方图标亦为黑标（SI 的 412991 存疑不采）——均归
///   近黑单色类，浅色近黑可见、深色退文字色（与 Kimi 同档）。
const Map<String, Color> _brandColors = {
  // 智谱 Z 标圆底（2026-11-18 圆底徽标批：Eta zai 圆同款黑；深色模式
  // 近黑提亮无意义→resolveBrandColor 返回 null 走中性圆回落）。
  'assets/brand_logos/zhipu.svg': Color(0xFF1C1C1E),
  'assets/brand_logos/claude.svg': Color(0xFFD97757),
  'assets/brand_logos/deepseek.svg': Color(0xFF4D6BFE),
  'assets/brand_logos/qwen.svg': Color(0xFF615CED),
  'assets/brand_logos/mistralai.svg': Color(0xFFFF7000),
  'assets/brand_logos/googlegemini.svg': Color(0xFF8E75B2),
  'assets/brand_logos/meta.svg': Color(0xFF0467DF),
  'assets/brand_logos/xiaomi.svg': Color(0xFFFF6900),
  'assets/brand_logos/minimax.svg': Color(0xFFE73562),
  'assets/brand_logos/nvidia.svg': Color(0xFF76B900),
  // Kimi/X(xAI)=品牌黑白（近黑类）：浅色用原色黑；深色提亮无意义→退前景色。
  'assets/brand_logos/kimi.svg': Color(0xFF000000),
  'assets/brand_logos/x.svg': Color(0xFF000000),
};

/// 品牌色深浅解析（2026-10-26 拍板①A）：
/// - 浅色模式=品牌原色；
/// - 深色模式=提亮品牌色（HSL 亮度抬到 0.72，保识别又保对比）；
/// - 近黑品牌（Kimi 等亮度 <0.12）深色下提亮即失去品牌感→返回 null
///   由调用侧退前景色。
Color? resolveBrandColor(String asset, Brightness brightness) {
  final brand = _brandColors[asset];
  if (brand == null) return null;
  final hsl = HSLColor.fromColor(brand);
  if (brightness == Brightness.light) return brand;
  if (hsl.lightness < 0.12) return null;
  if (hsl.lightness < 0.72) {
    return hsl.withLightness(0.72).toColor();
  }
  return brand;
}

/// 品牌小 logo。[color] 显式传入=沿用旧单色路径（欢迎屏水印等中性
/// 装饰用法）；null=品牌色自动策略（浅色原色/深色提亮，见
/// [resolveBrandColor]）。
class BrandLogo extends StatelessWidget {
  final String asset;
  final double size;
  final Color? color;

  const BrandLogo({
    super.key,
    required this.asset,
    this.size = 16,
    this.color,
  });

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        asset,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(
          color ??
              resolveBrandColor(asset, Theme.of(context).brightness) ??
              Theme.of(context).colorScheme.onSurface,
          BlendMode.srcIn,
        ),
      );
}


/// 圆底徽标（2026-11-18 用户拍板，Eta 同款）：固定直径的品牌色圆底 +
/// 白色单色字标——大小统一感来自圆底而非字标本体（各厂字形大小不一
/// 的"乱"根源在此根治）。
/// - 已知品牌（asset 有品牌色映射）：圆底=品牌色（浅色原色/深色提亮，
///   沿用 resolveBrandColor 策略；近黑品牌深色下圆底退中性灰）
/// - 未知品牌（无 SVG 资产，如 doubao/hunyuan/stepfun）：中性圆底 +
///   首字母白/前景字（官方彩色标与单色体系不同语言，暂不引入位图）
class BrandLogoChip extends StatelessWidget {
  final String modelId;
  final String? asset;
  final double size;

  const BrandLogoChip({
    super.key,
    required this.modelId,
    this.asset,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    // 圆底=品牌原色（深浅同色——圆底语义≠字标染色，深色下深色圆+
    // 白字标观感与 Eta 一致）。resolveBrandColor 的深色提亮是为字标
    // 染色设计的，圆底不需要。
    final tint = asset != null ? _brandColors[asset] : null;
    final bg = tint ?? Theme.of(context).colorScheme.secondaryContainer;
    final glyphColor = tint != null
        ? Colors.white
        : Theme.of(context).colorScheme.onSecondaryContainer;
    final glyphSize = size * 0.58;
    final assetPath = asset;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: assetPath != null
          ? SvgPicture.asset(
              assetPath,
              width: glyphSize,
              height: glyphSize,
              colorFilter: ColorFilter.mode(glyphColor, BlendMode.srcIn),
            )
          : Text(
              _brandChipInitial(modelId),
              maxLines: 1,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
                color: glyphColor,
              ),
            ),
    );
  }
}

/// 回退首字母（未知品牌圆底用）：取模型 id 首个字符大写。
String _brandChipInitial(String modelId) {
  final t = modelId.trim();
  if (t.isEmpty) return '?';
  return t.characters.first.toUpperCase();
}
