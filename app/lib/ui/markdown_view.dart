import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../core/code_highlight.dart';
import '../core/theme.dart';
import 'app_widgets.dart';

/// 选区工具条重锚（2026-11-19 用户实测 bug）：Flutter 的选区工具条
/// 用**静态锚点**——显示瞬间从选区几何算一次全局坐标放进根 Overlay，
/// 之后选区随文字移动（流式在上方增高/滚动）工具条不跟随：把手有
/// LayerLink 挂在渲染对象上贴得住，工具条没有=悬浮在旧位置盖住无关
/// 内容（截图实证：工具条盖住“工作中 X 分 X 秒”/气泡首行，高亮在两
/// 行之外）。SDK 无重锚事件——内容移动不产生 selection 变更。
/// 解法：周期对比锚点，动了才重建工具条（锚点从当前选区几何现算）。
/// 不动不重建=不干扰 ⋮ 二级菜单展开态；仅工具条在屏期间存活
/// （OverlayEntry 卸载即 dispose），200ms 步进开销可忽略。
class SelectionToolbarReanchor extends StatefulWidget {
  const SelectionToolbarReanchor({
    super.key,
    required this.anchors,
    required this.build,
    this.signature,
  });

  /// 当前锚点（每 tick 现取；primaryAnchor 变化即重建）。
  final TextSelectionToolbarAnchors Function() anchors;

  /// 工具条构建（闭包内现读 contextMenuButtonItems/contextMenuAnchors）。
  final Widget Function(TextSelectionToolbarAnchors anchors) build;

  /// 菜单内容指纹（如按钮标签串）——变化时重建（processText 异步加载等）。
  final Object? Function()? signature;

  @override
  State<SelectionToolbarReanchor> createState() =>
      _SelectionToolbarReanchorState();
}

class _SelectionToolbarReanchorState extends State<SelectionToolbarReanchor> {
  Timer? _ticker;
  TextSelectionToolbarAnchors? _last;
  Object? _lastSig;

  /// 同锚点复用同一工具条实例。SDK `_TextSelectionToolbarOverflowable`
  /// 在 didUpdateWidget 里对 children 做 listEquals——**实例身份变了就
  /// _reset() 关掉 ⋮ 二层菜单**（text_selection_toolbar.dart:176）。
  /// 工具条 entry 每次 markNeedsBuild 重跑 contextMenuBuilder 都现造
  /// 全新按钮 widgets=流式期间任何重建都会刷掉二层菜单（用户实测，
  /// 此前“对任何重建敏感”的机制本体）。缓存实例让同锚点重建整棵
  /// 跳过（identical widget → 子树不 rebuild → children 不变 → 不 reset）。
  Widget? _cached;

  void _check() {
    final a = widget.anchors();
    final s = widget.signature?.call();
    final moved = _last?.primaryAnchor != a.primaryAnchor;
    final itemsChanged = _lastSig != s;
    if (!moved && !itemsChanged) return;
    setState(() {
      _last = a;
      _lastSig = s;
      _cached = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) _check();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _cached ??= widget.build(_last ?? widget.anchors());
}

/// SelectionArea 侧（markdown 正文包层）的重锚工具条：等价默认
/// AdaptiveTextSelectionToolbar（无自定义项），带同锚点实例复用与跟随。
Widget reanchoringRegionToolbar(
  BuildContext context,
  SelectableRegionState region,
) => SelectionToolbarReanchor(
  anchors: () => region.contextMenuAnchors,
  signature: () => region.contextMenuButtonItems
      .map((i) => '${i.type}:${i.label}')
      .join('|'),
  build: (_) => AdaptiveTextSelectionToolbar.buttonItems(
    buttonItems: region.contextMenuButtonItems,
    anchors: region.contextMenuAnchors,
  ),
);

/// EditableText 侧（SelectableText/MarkdownBody）共用的重锚工具条——
/// 等价 SDK 默认 `AdaptiveTextSelectionToolbar.editableText`，外加跟随
/// 与同锚点实例复用（保 ⋮ 二层菜单不被重建刷掉）。
Widget reanchoringEditableTextToolbar(
  BuildContext context,
  EditableTextState state,
) => SelectionToolbarReanchor(
  anchors: () => state.contextMenuAnchors,
  // 内容指纹：processText 动作（Alook浏览器等）异步加载后要重建一次。
  signature: () =>
      state.contextMenuButtonItems.map((i) => '${i.type}:${i.label}').join('|'),
  build: (_) =>
      AdaptiveTextSelectionToolbar.editableText(editableTextState: state),
);

/// 本地路径链接预处理（早期反馈②b）：agent 回复常带
/// `[文件名](G:\path with space\文件.txt)`——路径含空格/反斜杠不是
/// 合法 CommonMark 目标，渲染器会原样输出。预处理把本地路径
/// 百分号编码成可解析链接，再由 a: 样式渲染为绿色文件名（桌面观感）。
final _localLinkRe = RegExp(
  r'\[([^\]\n]+)\]\(([A-Za-z]:\\[^)\n]*|/[^\s)][^)\n]*)\)',
);

String _encodeSegment(String s) => s.replaceAllMapped(_localLinkRe, (m) {
  final label = m.group(1)!;
  final path = m.group(2)!;
  // 契约：href 为百分号编码形态（含 %5C 反斜杠），解码在 onTapLink。
  return '[$label](${Uri.encodeFull(path)})';
});

String _encodeLocalLinks(String data) {
  // 围栏代码块与行内码内的路径不做改写（内容保真）。
  final blocks = data.split('```');
  final out = <String>[];
  for (var i = 0; i < blocks.length; i++) {
    if (i.isOdd) {
      out.add(blocks[i]);
      continue;
    }
    final spans = blocks[i].split('`');
    final seg = <String>[];
    for (var j = 0; j < spans.length; j++) {
      seg.add(j.isEven ? _encodeSegment(spans[j]) : spans[j]);
    }
    out.add(seg.join('`'));
  }
  return out.join('```');
}

/// 助手消息 markdown 渲染（阶段 1：基础排版；2026-11-04 换 flutter_markdown_plus）+
/// 代码语法高亮（批 2-5 解锁，2026-10-23 用户拍板：浅深两侧对齐官方
/// shiki github 同档+总开关；流式期间不高亮=官方策略）。
class MarkdownView extends StatelessWidget {
  final String data;
  final bool streaming;

  /// 语法高亮总开关（设置→对话；默认开）。由调用方从 uiPrefs 传入。
  final bool codeHighlightEnabled;

  /// 文本可选（2026-11-16 用户需求"输出的文字要能自由选中复制"）：
  /// 长按/双击进入系统级选择手柄+复制工具条。助手正文/工具输出/关于页
  /// 同走此默认开。
  /// **选区路径与用户气泡一致**（2026-11-19 真机对照）：markdown 固定
  /// 非可选渲染（MarkdownBody.selectable=false），整块包一层本文件的
  /// SelectionArea——选区盒由 RenderParagraph（字体原始度量）计算，
  /// 与气泡观感一致；包内 SelectableText+强制 strut 的
  /// includeLineSpacing 盒会把字体上下不对称放大（选区上下留白不均）。
  /// 每条消息独立 SelectionArea：流式消息自身重建不影响其他消息的选区。
  final bool selectable;

  const MarkdownView({
    super.key,
    required this.data,
    this.streaming = false,
    this.codeHighlightEnabled = true,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    final brightness = Theme.of(context).brightness;
    // 审查 A 组修复（2026-10-23）：pre 构建器接管了全部块码渲染，其
    // 样式/内边距必须与 copyWith 后的最终 styleSheet 同源——原先传
    // fromTheme 出厂值（padding 8/字号 11.9/文字实心底色），与包默认
    // 路径消费的最终值（12/13/无底色）四项不一致=视觉回归。故先把
    // 最终表算出来，builders 与 styleSheet: 两处共用。
    final styleSheet = _buildStyleSheet(context, base);
    // 块码语言预提取：markdown 包把 ```lang 放进 code 元素 attributes，
    // 但块码构建走 'pre' 的 visitText 路径拿不到 attributes（builder.dart
    // :405-409 实证）——从原文把「代码文本→语言」先抽成表，pre 构建器
    // 按文本反查（同内容多块同语言，键不敏感）。禁用/流式时跳过全文
    // 正则扫描（审查 B：流式期间 O(n²)/帧纯浪费）。
    final highlightOn = codeHighlightEnabled && !streaming;
    final languages = highlightOn
        ? _fenceLanguages(data)
        : const <String, String>{};
    final body = MarkdownBody(
      selectable: false,
      data: _encodeLocalLinks(streaming ? '$data ▍' : data),
      builders: {
        'pre': _PreHighlightBuilder(
          brightness: brightness,
          enabled: highlightOn,
          baseStyle: _stripBackground(
            styleSheet.code ?? const TextStyle(fontFamily: 'monospace'),
          ),
          languages: languages,
          padding: styleSheet.codeblockPadding ?? const EdgeInsets.all(12),
        ),
      },
      // 点链接的响应分两类（批4 反馈④，2026-10-23 用户拍板）：
      // - 本地文件路径：协议层无文件内容读取 RPC（ZCode 官方开源实现
      //   zcode-protocol-v4 全量 grep 实证，桌面预览是本地读盘），复制
      //   路径在手机端无实用价值——点击不做任何响应（绿色渲染保留）。
      // - 网络链接：保持可点（提示+复制）。
      onTapLink: (text, href, title) {
        if (href == null || href.isEmpty) return;
        // 非 ASCII/非法 %xx 会让 decodeFull 抛 ArgumentError——
        // 守卫解码，失败用原样。
        String decoded;
        try {
          decoded = Uri.decodeFull(href);
        } catch (_) {
          decoded = href;
        }
        final isLocal =
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(decoded) ||
            decoded.startsWith('/');
        if (isLocal) return;
        Clipboard.setData(ClipboardData(text: decoded));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('链接：$decoded'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      styleSheet: styleSheet,
    );
    if (!selectable) {
      return L10nScope(enabled: false, child: body);
    }
    // 选区路径对齐用户气泡（见 selectable 字段注释）。
    return L10nScope(
      enabled: false,
      child: SelectionArea(
        contextMenuBuilder: reanchoringRegionToolbar,
        child: body,
      ),
    );
  }

  /// 最终样式表（审查 A 组修复抽出）：builders 与 styleSheet 共用同一
  /// 实例，防两处取值漂移。
  MarkdownStyleSheet _buildStyleSheet(
    BuildContext context,
    MarkdownStyleSheet base,
  ) => base.copyWith(
    // 排版密度对齐官方（2026-10-22 对抗审查收敛项：正文 1.6 无字距
    // vs 官方 leading-[1.75] tracking-wide，message.tsx:1368）。
    p: TextStyle(
      fontSize: AppType.uiBase,
      color: context.colors.foreground,
      // 验收回填（2026-10-22 三档反馈）：1.6 太紧/1.75 稍松 → 1.7。
      height: 1.7,
      // 行距上下均分（对齐 CSS line-height 的 half-leading 模型）：
      // Flutter 默认 proportional 按字体 ascent/descent 比例分配，
      // 中文字体不对称 → 选中时行内上下留白明显不均（桌面均匀）。
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0.2,
    ),
    listBullet: TextStyle(
      fontSize: AppType.uiBase,
      // 官方 marker:text-foreground-subtlest（markdown-list.tsx:20,43）
      // ——序号/bullet 比正文退一档，不再同浓。
      color: context.colors.foregroundSubtlest,
      height: 1.7,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    // 标题分节呼吸感：官方 h1=18/h2=16/h3=14 且统一 mt-6 mb-4
    // （message.tsx:441-446）——此前零边距挤成一块。
    h1: const TextStyle(fontSize: AppType.uiXl, fontWeight: FontWeight.w600),
    h2: const TextStyle(fontSize: AppType.uiLg, fontWeight: FontWeight.w600),
    h3: const TextStyle(fontSize: AppType.uiBase, fontWeight: FontWeight.w600),
    h1Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
    h2Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
    h3Padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
    blockSpacing: 12,
    // 引用块对齐官方（markdown-blockquote.tsx:14）：无底色无圆角，
    // 2px 左线+左 12 缩进+subtle 文字——此前 surface 底卡观感。
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: context.colors.border, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: AppType.uiCaption,
      color: context.colors.foreground,
      leadingDistribution: TextLeadingDistribution.even,
      // 行内代码底色对齐桌面（renderer styles CSS 实证：
      // --color-markdown-inline-code=tag 50%——浅色 #E6E6E6/50、
      // 深色 #363636/50）。显式设置同时覆盖掉 MarkdownBody 内部
      // fallback.merge 残留的卡片白底（TextStyle.merge 只能覆盖
      // 不能清除路径，此前浅色主题行内代码=白底异色块）。
      // 注：TextSpan 底色是直角矩形（桌面为圆角），文本 span 不支持
      // 圆角，属 Flutter 渲染限制。
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0x80363636)
          : const Color(0x80E6E6E6),
    ),
    // 代码块圆角对齐官方 rounded-xl(12)（code-block.tsx:155）。
    codeblockDecoration: BoxDecoration(
      color: context.colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.block),
      border: Border.all(color: context.colors.border),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    tableBorder: TableBorder.all(
      color: context.colors.border,
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    tableCellsDecoration: BoxDecoration(color: context.colors.card),
    // flutter_markdown_plus（2026-11-04 换包）新增表头单元格装饰，
    // 且默认回退 tableCellsDecoration——表头会被染成 card 底色，
    // 与旧包"表头透明、仅偶数数据行着色"的既有观感不一致。依赖替换
    // 不应夹带设计变更：显式透明把表头钉回旧观感（A/B 像素差归零）。
    tableHeadCellsDecoration: const BoxDecoration(),
    // 表格手机端优化（2026-10-20 用户反馈"表格没针对手机优化"）：
    // 默认 FlexColumnWidth 把列硬塞进屏宽=与桌面同款挤压；改
    // IntrinsicColumnWidth（列宽随内容）后渲染器自动
    // 包横向 SingleChildScrollView+Scrollbar——宽表滚动看，窄表原样。
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    blockquote: TextStyle(
      fontSize: AppType.uiBase,
      color: context.colors.foregroundSubtle,
      height: 1.7,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    // ②b：文件链接=绿色文件名（无下划线，桌面观感）。
    a: TextStyle(
      fontSize: AppType.uiBase,
      color: context.colors.success,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// 原文围栏语言提取：```lang\n...\n``` → {代码文本.trim(): lang}。
Map<String, String> _fenceLanguages(String data) {
  final map = <String, String>{};
  final re = RegExp(
    '^```([A-Za-z0-9+#._-]*)[^\\n]*\\n(.*?)^```',
    multiLine: true,
    dotAll: true,
  );
  for (final m in re.allMatches(data)) {
    final lang = m.group(1) ?? '';
    final code = m.group(2) ?? '';
    if (lang.isNotEmpty) map[code.trim()] = lang;
  }
  return map;
}

/// 去掉实心底色的样式副本：行内 code 底色只属于行内标签——块码自带
/// codeblockDecoration 卡底，若继承行内底色会把整块文字染成标签灰。
/// `TextStyle.copyWith` 无法把字段清回 null，故逐字段重建。
TextStyle _stripBackground(TextStyle s) => TextStyle(
  inherit: s.inherit,
  color: s.color,
  fontSize: s.fontSize,
  fontWeight: s.fontWeight,
  fontStyle: s.fontStyle,
  letterSpacing: s.letterSpacing,
  wordSpacing: s.wordSpacing,
  textBaseline: s.textBaseline,
  height: s.height,
  leadingDistribution: s.leadingDistribution,
  locale: s.locale,
  foreground: s.foreground,
  shadows: s.shadows,
  fontFeatures: s.fontFeatures,
  fontVariations: s.fontVariations,
  decoration: s.decoration,
  decorationColor: s.decorationColor,
  decorationStyle: s.decorationStyle,
  decorationThickness: s.decorationThickness,
  debugLabel: s.debugLabel,
  fontFamily: s.fontFamily,
  fontFamilyFallback: s.fontFamilyFallback,
);

/// pre 块构建器：visitText 拿到围栏内原始文本，按预提取表反查语言着色；
/// 查不到/禁用/跳过语言一律返回 null 走包默认渲染（横向滚动+底色壳
/// 均为包内行为）。着色分支自建横向滚动（包的 _ScrollControllerBuilder
/// 不外露），底色/描边壳由包的 codeblockDecoration 外层照常提供。
class _PreHighlightBuilder extends MarkdownElementBuilder {
  _PreHighlightBuilder({
    required this.brightness,
    required this.enabled,
    required this.baseStyle,
    required this.languages,
    required this.padding,
  });

  final Brightness brightness;
  final bool enabled;
  final TextStyle baseStyle;
  final Map<String, String> languages;
  final EdgeInsets padding;

  @override
  Widget? visitText(md.Text text, TextStyle? style) {
    // 块级 builder 不允许返回 null（包内 _inlines.isEmpty 断言，禁用
    // 路径实证踩坑）——不高亮时自兜底复刻默认渲染（横向滚动+滚动条+
    // padding+mono 文本），保证关闭开关后与旧纯文本观感一致。
    // 审查 （双员交叉命中）：包默认 formatText 会剥一个尾换行
    // （widget.dart:454-459），自定义路径原样渲染=每块多一行空行——
    // 高亮/纯文本两路都先剥（与缓存 key 一致性由 trim 保证）。
    var source = text.text;
    while (source.endsWith('\n') || source.endsWith('\r')) {
      source = source.substring(0, source.length - 1);
    }
    final language = enabled ? languages[source.trim()] : null;
    final spans = language != null
        ? highlightCode(source, language, brightness: brightness)
        : null;
    // 2026-10-23 用户反馈批：代码块一键复制（官方 CodeBlockCopyButton
    // code-block.tsx:454 对位，复制代码原文非渲染文本）。
    // B 方案（2026-11-17 用户拍板）：语言标签+复制键改为代码块上方
    // 独立头行（右对齐）——旧实现悬浮右上角与首行长文本重叠（单行
    // 块 bash 命令等首屏即撞，用户实测）；头行在包的 codeblockDecoration
    // 容器内，随代码卡同底色，永不遮内容。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (language != null)
                Builder(
                  builder: (context) => Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Text(
                      language,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ),
                ),
              CopyIconButton(
                text: source,
                tooltip: tr('复制代码'),
                snackText: '代码已复制',
              ),
            ],
          ),
        ),
        _PreScroll(
          padding: padding,
          child: spans != null
              ? Text.rich(
                  TextSpan(style: baseStyle, children: spans),
                  softWrap: false,
                )
              : Text(source, style: baseStyle, softWrap: false),
        ),
      ],
    );
  }
}

/// 包内默认 pre 的滚动壳复刻（_ScrollControllerBuilder 私有不可复用；
/// 独立 controller 视觉等价——共享 controller 只是包的多块优化）。
class _PreScroll extends StatefulWidget {
  const _PreScroll({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  State<_PreScroll> createState() => _PreScrollState();
}

class _PreScrollState extends State<_PreScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}
