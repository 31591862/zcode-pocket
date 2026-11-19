// 选区工具条重锚（2026-11-19 用户实测 ⋮ 二层菜单被刷掉）：
// SDK `_TextSelectionToolbarOverflowable.didUpdateWidget` 对 children
// 做 listEquals——实例身份变了就 _reset() 关闭二层菜单。工具条 entry
// 每次重建重跑 contextMenuBuilder 都现造新按钮 widgets=任何重建都刷掉
// 二层。SelectionToolbarReanchor 的同锚点实例复用让子树整体跳过。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';

void main() {
  testWidgets('同锚点父重建不刷新工具条；锚点移动才重建', (tester) async {
    var builds = 0;
    var anchor = const Offset(10, 10);

    late StateSetter rebuildParent;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return SelectionToolbarReanchor(
              anchors: () =>
                  TextSelectionToolbarAnchors(primaryAnchor: anchor),
              build: (_) {
                builds++;
                return const SizedBox(
                  key: ValueKey('toolbar'),
                  width: 10,
                  height: 10,
                );
              },
            );
          },
        ),
      ),
    );
    expect(builds, 1);

    // 父级重建（模拟工具条 entry markNeedsBuild）：同锚点 → 复用缓存
    // 实例，工具条子树不重建 → SDK children 不变 → ⋮ 二层不 reset。
    rebuildParent(() {});
    await tester.pump();
    expect(builds, 1, reason: '同锚点重建不得刷新工具条（否则 ⋮ 二层被刷掉）');

    // 锚点移动（选区随内容移动/滚动）→ 重建工具条跟随。
    anchor = const Offset(50, 50);
    await tester.pump(const Duration(milliseconds: 250));
    expect(builds, 2, reason: '锚点变化必须重建以跟随选区');

    // 再次同锚点父重建：依旧复用。
    rebuildParent(() {});
    await tester.pump();
    expect(builds, 2);

    // 卸载释放 ticker。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('内容指纹变化重建（processText 异步加载等）', (tester) async {
    var builds = 0;
    var sig = 'a';
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionToolbarReanchor(
          anchors: () =>
              const TextSelectionToolbarAnchors(primaryAnchor: Offset(0, 0)),
          signature: () => sig,
          build: (_) {
            builds++;
            return const SizedBox(width: 10, height: 10);
          },
        ),
      ),
    );
    expect(builds, 1);

    sig = 'a|b';
    await tester.pump(const Duration(milliseconds: 250));
    expect(builds, 2, reason: '菜单项变化（新 processText 动作）必须重建');

    await tester.pumpWidget(const SizedBox());
  });
}
