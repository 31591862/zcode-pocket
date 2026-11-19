// 反向列表几何验收（2026-11-19 反向列表实验）：
// - offset 0 = 列表底部：末条贴底、更早条目在上方；
// - 追加新条目（流式新回合）不动当前视口内容——贴底零位移；
// - 视口尺寸变化（横幅显隐/键盘）不动底部内容。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/anchored_chat_list.dart';

Widget _host({
  required List<String> items,
  required ScrollController controller,
  int? centerIndex,
  double viewportHeight = 600,
}) {
  return MaterialApp(
    home: Scaffold(
      // 顶部对齐的松约束——SizedBox 高度生效且底边随高度下移
      // （Center 会让上下两边对半分）。
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: viewportHeight,
          width: 400,
          child: AnchoredChatList(
            controller: controller,
            itemCount: items.length,
            centerIndex: centerIndex ?? items.length - 1,
            itemBuilder: (context, index) => SizedBox(
              key: ValueKey('item-$index'),
              height: 100,
              child: Text(items[index]),
            ),
            leading: items.isNotEmpty
                ? const SizedBox(key: ValueKey('load-older'), height: 40)
                : null,
            trailing: const SizedBox(key: ValueKey('trailing'), height: 30),
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('反向布局：末条贴底，更早条目在上方', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final items = ['old', 'mid', 'new'];
    await tester.pumpWidget(_host(items: items, controller: controller));

    expect(controller.offset, 0, reason: '初始 offset=0=底部');
    final newY = tester.getTopLeft(find.byKey(const ValueKey('item-2'))).dy;
    final midY = tester.getTopLeft(find.byKey(const ValueKey('item-1'))).dy;
    final oldY = tester.getTopLeft(find.byKey(const ValueKey('item-0'))).dy;
    expect(newY, greaterThan(midY), reason: '最新条目在更早条目下方');
    expect(midY, greaterThan(oldY));
    // 末条底边贴 trailing（trailing 在锚点下方、紧贴底部边缘）
    final newRect = tester.getRect(find.byKey(const ValueKey('item-2')));
    final trailingRect = tester.getRect(find.byKey(const ValueKey('trailing')));
    expect(
      newRect.bottom,
      lessThanOrEqualTo(trailingRect.top + 0.5),
      reason: '末条在 trailing 上方（trailing 贴底）',
    );
  });

  testWidgets('追加新条目：贴底视口零位移', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final items = ['a', 'b', 'c', 'd', 'e', 'f'];
    await tester.pumpWidget(_host(items: items, controller: controller));
    expect(controller.offset, 0);

    final before = tester.getRect(find.byKey(const ValueKey('item-5')));

    // 追加新条目（流式新回合到达）——center 跟随末条。
    items.add('g');
    await tester.pumpWidget(_host(items: items, controller: controller));
    await tester.pump();

    expect(controller.offset, 0, reason: '贴底态追加内容不得移动滚动位置');
    final after = tester.getRect(find.byKey(const ValueKey('item-5')));
    // 旧末条被新条目顶上去 100px：这是"新消息把旧消息顶上去"的自然语义。
    expect(
      before.top - after.top,
      closeTo(100, 1),
      reason: '旧内容整体上移=新条目高度（自然滚动语义，不是跳动）',
    );
    // 新条目贴底出现
    expect(controller.offset, 0);
    expect(find.byKey(const ValueKey('item-6')), findsOneWidget);
  });

  testWidgets('视口高度变化：底部内容位置不动', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final items = List.generate(10, (i) => 'm$i');
    await tester.pumpWidget(_host(items: items, controller: controller));
    expect(controller.offset, 0);
    final before = tester.getRect(find.byKey(const ValueKey('item-9')));

    // 视口增高 40（横幅消失/键盘收起）
    await tester.pumpWidget(
      _host(items: items, controller: controller, viewportHeight: 640),
    );
    await tester.pump();

    expect(controller.offset, 0, reason: '视口变化不得改变底部锚定');
    final after = tester.getRect(find.byKey(const ValueKey('item-9')));
    expect(
      after.bottom - before.bottom,
      closeTo(40, 1),
      reason: '底部内容随视口底边移动（相对视口位置不变）',
    );
  });
}
