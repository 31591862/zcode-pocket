import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 以稳定条目为锚的**反向**双向懒列表（2026-11-19 反向列表实验）。
///
/// 视口 `reverse: true`：**滚动 offset 0 = 列表底部**——聊天贴底语义的
/// 原生实现：
///
/// - 追加内容（实时帧追加新回合/流式增长）只影响 offset 0 以上的
///   正向区，贴底位置（pixels=minScrollExtent）天然不动；
/// - 惰性列表的估算修正只影响远端（更早历史），不产生可见位移；
///   视口顶部的视口尺寸变化（缓存横幅显隐/键盘）同样不移动底部内容；
/// - 历史前插（加载更早）增长正区远端，也不移动当前阅读位置——
///   不需要任何 postFrame 补偿。
///
/// 结构（视觉自上而下 = 列表 ③②① 顺序，offset 0 在底部）：
/// ③ 正向区（屏幕上方）：锚点之前的条目 ci-1..0、leading（加载更早）、顶距；
/// ② center 锚点区（offset 0 起向上）：[底距] [trailing] [锚点条目]——
///    底部边缘从底距开始，trailing（"正在思考…"占位）与末条消息紧贴底边；
/// ① 负向区（屏幕底部之外）：比锚点新的条目（正常贴尾时为空；搜索/定位
///    临时把远条目设为锚点时，新于锚点的内容挂在这里，可向下回滚）。
///
/// 页面默认把 centerIndex 钉在末条（贴尾跟随不漂移）；搜索跳转/回合
/// 定位时临时把目标条设为锚点，回到贴底时复位。
class AnchoredChatList extends StatelessWidget {
  static const _centerKey = ValueKey('anchored-chat-center');

  final ScrollController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final int centerIndex;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsets padding;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  const AnchoredChatList({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.centerIndex,
    this.leading,
    this.trailing,
    this.padding = EdgeInsets.zero,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
  }) : assert(itemCount >= 0),
       assert(centerIndex >= 0),
       assert(itemCount == 0 || centerIndex < itemCount),
       // itemCount==0 时 afterCenter=-1 会把 trailing
       // 静默吞成底距 SizedBox——潜伏地雷（当前调用方用 isNotEmpty 守住，
       // 留断言防未来调用方踩入）。
       assert(
         itemCount > 0 || trailing == null,
         'trailing requires itemCount>0',
       );

  @override
  Widget build(BuildContext context) {
    final horizontal = EdgeInsets.only(
      left: padding.left,
      right: padding.right,
    );
    // 比锚点新的条目数（挂在锚点下方=负向区=屏幕底部之外）。
    final afterCenter = math.max(0, itemCount - centerIndex - 1);
    // center sliver 自底向上的子项：[底距] [trailing] [锚点]。
    final bottomPadCount = padding.bottom > 0 ? 1 : 0;
    final centerCount =
        bottomPadCount + (trailing == null ? 0 : 1) + (itemCount > 0 ? 1 : 0);
    // 锚点上方：ci-1..0 + leading + 顶距。
    final aboveCount = centerIndex + (leading == null ? 0 : 1) + 1;

    return CustomScrollView(
      controller: controller,
      // 核心：反向视口，offset 0 = 底部（最新内容）。
      reverse: true,
      center: _centerKey,
      physics: const ClampingScrollPhysics(),
      keyboardDismissBehavior: keyboardDismissBehavior,
      slivers: [
        // ① 负向区（屏幕底部之外）：比锚点新的条目。
        SliverPadding(
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => itemBuilder(context, centerIndex + index + 1),
              childCount: afterCenter,
            ),
          ),
        ),
        // ② center 锚点区（offset 0 起向上）：底距 → trailing → 锚点。
        SliverPadding(
          key: _centerKey,
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              var i = index;
              if (bottomPadCount == 1 && i == 0) {
                return SizedBox(height: padding.bottom);
              }
              i -= bottomPadCount;
              if (trailing != null && i == 0) return trailing!;
              i -= trailing == null ? 0 : 1;
              if (i == 0 && itemCount > 0) {
                return itemBuilder(context, centerIndex);
              }
              return const SizedBox.shrink();
            }, childCount: centerCount),
          ),
        ),
        // ③ 正向区（屏幕上方）：锚点之前的条目向上铺开 + leading + 顶距。
        SliverPadding(
          padding: horizontal,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index < centerIndex) {
                return itemBuilder(context, centerIndex - index - 1);
              }
              if (leading != null && index == centerIndex) {
                return Padding(
                  padding: EdgeInsets.only(top: padding.top),
                  child: leading,
                );
              }
              return SizedBox(height: padding.top);
            }, childCount: aboveCount),
          ),
        ),
      ],
    );
  }
}
