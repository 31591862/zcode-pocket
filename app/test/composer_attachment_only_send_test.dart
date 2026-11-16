// 纯附件发送（2026-11-16 用户反馈"对话中只添加附件时候无法发送，
// 必须要输入几个文字才行"）：修复前两道门——
// ① _send/_sendText 的空文本早退；
// ② InputBar 发送键空文本退麦克风/停止键（点按拉语音不发送）。
// 修复：托盘有附件（hasAttachments）时空文本保持发送态，点按走 onSend；
// 无附件空文本的麦克风回退惯例不回归（voice_entry_availability_test 既有
// 断言不受影响）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/conversation_composer.dart';

Future<void> pumpBar(
  WidgetTester tester, {
  required TextEditingController controller,
  required FocusNode focusNode,
  required bool running,
  required bool hasAttachments,
  required void Function() onSend,
  required void Function() onStop,
  required void Function() onVoice,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: InputBar(
          controller: controller,
          focusNode: focusNode,
          running: running,
          sending: false,
          onSend: onSend,
          onStop: onStop,
          hasAttachments: hasAttachments,
          onVoice: onVoice,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('托盘有附件+空文本：发送键亮发送态，点按发 onSend 不拉语音', (tester) async {
    var sent = 0;
    var voiceOpened = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      running: false,
      hasAttachments: true,
      onSend: () => sent++,
      onStop: () {},
      onVoice: () => voiceOpened++,
    );
    expect(find.byIcon(Icons.mic_rounded), findsNothing,
        reason: '有附件空文本不再退麦克风态（bug：点按=语音不发送）');
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(sent, 1, reason: '纯附件可发送');
    expect(voiceOpened, 0);
  });

  testWidgets('无附件空文本：麦克风回退照旧（既有惯例不回归）', (tester) async {
    var sent = 0;
    var voiceOpened = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      running: false,
      hasAttachments: false,
      onSend: () => sent++,
      onStop: () {},
      onVoice: () => voiceOpened++,
    );
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(voiceOpened, 1, reason: '空文本无附件=点按直达语音（2026-10-22 惯例）');
    expect(sent, 0);
  });

  testWidgets('运行中+托盘附件：保持发送键（发送即排队），描边停止键并排照旧', (tester) async {
    var sent = 0;
    var stopped = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      running: true,
      hasAttachments: true,
      onSend: () => sent++,
      onStop: () => stopped++,
      onVoice: () {},
    );
    // 运行中+有草稿（附件=发送意图）：主键=发送（不进"实心停止键"独占态），
    // 描边停止键并排（V2 单键切换的既有设计）。
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(sent, 1, reason: '运行中点发送=排队语义保留');
    await tester.tap(find.byKey(const ValueKey('stop-button')));
    await tester.pump();
    expect(stopped, 1, reason: '描边停止键并排照旧');
  });

  testWidgets('运行中+无附件空文本：停止键照旧', (tester) async {
    var stopped = 0;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pumpBar(
      tester,
      controller: controller,
      focusNode: focusNode,
      running: true,
      hasAttachments: false,
      onSend: () {},
      onStop: () => stopped++,
      onVoice: () {},
    );
    expect(find.byKey(const ValueKey('stop-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stop-button')));
    await tester.pump();
    expect(stopped, 1);
  });
}
