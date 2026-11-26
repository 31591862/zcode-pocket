// 「视觉」标签测试夹具（多处模型选择弹层的组件测试共用，非测试体）。
//
// 目录条目=modelSelectionRawOptions 的产出形状（value=providerId/modelId
// + provider 分组/套餐元数据 + 接入类型 + 图片输入事实）。两种接入方式 ×
// 三种标签形态（标 / 套餐例外不标 / 无能力不标）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';

const visionPlanPid = 'account:bigmodel-individual-coding-plan';
const visionApiPid = 'opencode-zen';

List<ConfigOption> visionCatalogOptions() => [
  ConfigOption.fromMap(const {
    'id': 'model',
    'name': 'Model',
    'options': [
      {
        'value': '$visionPlanPid/glm-5.3',
        'name': 'glm-5.3',
        'modelProviderId': visionPlanPid,
        'modelAccessMode': 'individual-coding-plan',
        'modelAccessAccountType': 'bigmodel',
        'modelAccessType': 'zhipu-account',
        'modelSupportsImage': true,
      },
      {
        'value': '$visionPlanPid/glm-5.3-flash',
        'name': 'glm-5.3-flash',
        'modelProviderId': visionPlanPid,
        'modelAccessMode': 'individual-coding-plan',
        'modelAccessAccountType': 'bigmodel',
        'modelAccessType': 'zhipu-account',
        'modelSupportsImage': true,
      },
      {
        'value': '$visionPlanPid/glm-5.3-air',
        'name': 'glm-5.3-air',
        'modelProviderId': visionPlanPid,
        'modelAccessMode': 'individual-coding-plan',
        'modelAccessAccountType': 'bigmodel',
        'modelAccessType': 'zhipu-account',
        'modelSupportsImage': false,
      },
      {
        'value': '$visionApiPid/claude-sonnet-4.5',
        'name': 'claude-sonnet-4.5',
        'modelProviderId': visionApiPid,
        'modelProviderName': 'OCG',
        'modelAccessType': 'api-key',
        'modelSupportsImage': true,
      },
      {
        'value': '$visionApiPid/glm-5.3',
        'name': 'glm-5.3',
        'modelProviderId': visionApiPid,
        'modelProviderName': 'OCG',
        'modelAccessType': 'api-key',
        'modelSupportsImage': true,
      },
    ],
  }),
];

/// 行内「视觉」标签的文字（按文本定位，不依赖标签组件类型）。
Finder visionBadgeInRow(String rowKey) => find.descendant(
  of: find.byKey(ValueKey(rowKey)),
  matching: find.text('视觉'),
);

/// 标签紧跟模型名称右侧（桌面端 ModelConfigSelect 同位：6dp 间距，
/// 胶囊左缘=模型名右缘 + 6dp，标签文字左缘=胶囊左缘 + 5dp，即间距约 11dp，
/// 绝不被推到行最右侧）。
void expectVisionBadgeFollowsModelName(
  WidgetTester tester,
  String rowKey,
  String modelName,
) {
  final row = find.byKey(ValueKey(rowKey));
  final nameFinder = find.descendant(of: row, matching: find.text(modelName));
  final badgeFinder = visionBadgeInRow(rowKey);
  expect(nameFinder, findsOneWidget);
  expect(badgeFinder, findsOneWidget);
  final nameRight = tester.getTopRight(nameFinder).dx;
  final badgeTextLeft = tester.getTopLeft(badgeFinder).dx;
  // 6dp SizedBox + 1dp border + 4dp horizontal padding = 11dp
  final gap = badgeTextLeft - nameRight;
  expect(gap, greaterThanOrEqualTo(9.0), reason: '标签与模型名之间留 6dp 间距');
  expect(gap, lessThanOrEqualTo(14.0), reason: '标签必须紧跟模型名右侧，不推到最右');
}

/// 子代理页模型分组弹层的标准断言（行内覆盖、编辑器两个入口共用）。
/// 调用前提：弹层已打开；套餐组默认展开，API 组由本函数展开。
Future<void> expectVisionBadgesInSubagentSheet(WidgetTester tester) async {
  Finder badgeIn(String value) =>
      visionBadgeInRow('subagent-model-option-$value');
  expect(badgeIn('$visionPlanPid/glm-5.3'), findsNothing,
      reason: '官方展示例外：套餐接入下的 glm-5.3 不标');
  expect(badgeIn('$visionPlanPid/glm-5.3-flash'), findsOneWidget);
  expect(badgeIn('$visionPlanPid/glm-5.3-air'), findsNothing);

  final header = find.byKey(
    ValueKey('subagent-model-group-$visionApiPid'),
  );
  expect(header, findsOneWidget);
  await tester.tap(header);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(badgeIn('$visionApiPid/claude-sonnet-4.5'), findsOneWidget);
  expect(badgeIn('$visionApiPid/glm-5.3'), findsOneWidget,
      reason: '例外只限套餐接入——API 渠道的 glm-5.3 照标');
  expect(find.text('视觉'), findsNWidgets(3));
  expectVisionBadgeFollowsModelName(
    tester,
    'subagent-model-option-$visionPlanPid/glm-5.3-flash',
    'glm-5.3-flash',
  );
  expectVisionBadgeFollowsModelName(
    tester,
    'subagent-model-option-$visionApiPid/glm-5.3',
    'glm-5.3',
  );
}
