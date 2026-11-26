// 模型「视觉」标签·判定与取数（纯函数层）。
//
// 判定=官方 modelVisionBadge.ts shouldShowModelVisionBadge 的逐句镜像
// （仅 supportsImage===true；套餐接入下的 glm-5.3 展示例外；只控标签
// 不改能力事实）。取数=官方 model-selection.getView 响应的真实 wire
// 形态夹具经生产解析 modelSelectionRawOptions。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/model_vision_badge.dart';

Map<String, dynamic> _planAccess({
  String mode = 'individual-coding-plan',
}) => {
  'type': 'zhipu-account',
  'accountType': 'bigmodel',
  'mode': mode,
  'entitled': true,
};

/// 官方 serializeRegistryModelConfig 的 properties 形态。
Map<String, dynamic> _properties({Object? supportsImage = true}) => {
  'requiresMfjsToolSchema': false,
  'contextWindow': 200000,
  'inputFormat': {
    'supportsText': true,
    'supportsImage': supportsImage,
    'supportsVideo': false,
    'supportsAudio': false,
    'supportsPdf': false,
  },
  'outputFormat': {'supportsText': true},
  'supportsToolCall': true,
  'supportsJsonSchemaOutput': false,
  'supportsNativeWebSearch': false,
  'supportsMidConversationSystem': false,
};

/// 一 provider 一 model 的最小 getView 响应；modelConfig 原样放入。
Map<String, dynamic> _view({
  required Map<String, dynamic> access,
  required Map<String, dynamic> modelConfig,
  String pid = 'prov-example',
  String mid = 'model-example',
}) => {
  'revision': 1,
  'providers': [
    {
      'providerId': pid,
      'providerName': 'Example Provider',
      'templateId': 'tpl-example',
      'config': {
        'group': 'standard-personal',
        'access': access,
        'api': {'type': 'glm', 'baseUrl': 'https://example.invalid/v4'},
      },
      'models': [
        {'modelId': mid, 'config': modelConfig},
      ],
    },
  ],
};

Map<String, Object?> _single(Map<String, dynamic> view) =>
    modelSelectionRawOptions(view).single;

void main() {
  group('shouldShowModelVisionBadge（官方规则逐句镜像）', () {
    test('仅 supportsImage === true 才可能显示（null/false 一律不标）', () {
      for (final access in [
        {'accessType': 'api-key'},
        {'accessType': 'zhipu-account', 'accessMode': 'individual-coding-plan'},
        {'accessType': 'zhipu-coding-plan-api-key'},
        const <String, String>{},
      ]) {
        for (final model in ['glm-5.3', 'glm-5.3-flash', 'claude-sonnet-4.5']) {
          expect(
            shouldShowModelVisionBadge(
              model,
              null,
              accessType: access['accessType'],
              accessMode: access['accessMode'],
            ),
            isFalse,
            reason: '目录没给事实：$model $access',
          );
          expect(
            shouldShowModelVisionBadge(
              model,
              false,
              accessType: access['accessType'],
              accessMode: access['accessMode'],
            ),
            isFalse,
            reason: '目录说不支持：$model $access',
          );
        }
      }
      expect(shouldShowModelVisionBadge('glm-5.3', true), isTrue);
      expect(
        shouldShowModelVisionBadge('glm-5.3-flash', true, accessType: 'api-key'),
        isTrue,
      );
    });

    test('展示例外：套餐接入下的 glm-5.3 不标（图片输入是服务端桥接）', () {
      const planAccesses = <(String, String?)>[
        ('zhipu-coding-plan-api-key', null),
        ('zhipu-account', 'individual-coding-plan'),
        ('zhipu-account', 'team-coding-plan'),
        ('zhipu-account', 'start-plan'), // 体验套餐同在例外之内
      ];
      for (final (type, mode) in planAccesses) {
        expect(
          shouldShowModelVisionBadge(
            'glm-5.3',
            true,
            accessType: type,
            accessMode: mode,
          ),
          isFalse,
          reason: '$type/$mode 下的 glm-5.3 不得标成原生视觉',
        );
      }
    });

    test('例外只认 glm-5.3：套餐下的其他型号照标', () {
      for (final model in ['glm-5.3-flash', 'glm-5.3-air', 'glm-4.7', 'glm-5.4']) {
        expect(
          shouldShowModelVisionBadge(
            model,
            true,
            accessType: 'zhipu-account',
            accessMode: 'individual-coding-plan',
          ),
          isTrue,
          reason: model,
        );
      }
    });

    test('例外只限套餐接入：API 渠道的 glm-5.3 照标', () {
      expect(
        shouldShowModelVisionBadge('glm-5.3', true, accessType: 'api-key'),
        isTrue,
      );
      // 接入类型与模式成对判定：非 zhipu-account 类型即使带套餐模式
      // 字样也不触发例外。
      expect(
        shouldShowModelVisionBadge(
          'glm-5.3',
          true,
          accessType: 'api-key',
          accessMode: 'individual-coding-plan',
        ),
        isTrue,
      );
      // 接入信息缺失=无从判定为套餐，不触发例外。
      expect(
        shouldShowModelVisionBadge(
          'glm-5.3',
          true,
          accessMode: 'individual-coding-plan',
        ),
        isTrue,
      );
    });

    test('非套餐账号档不在例外内（与官方枚举一致，不自行扩大）', () {
      for (final mode in ['off-peak', 'highspeed']) {
        expect(
          shouldShowModelVisionBadge(
            'glm-5.3',
            true,
            accessType: 'zhipu-account',
            accessMode: mode,
          ),
          isTrue,
          reason: '$mode 不在官方例外枚举内',
        );
      }
    });

    test('型号比对=小写化后全等（大小写不敏感，不做前缀/子串匹配）', () {
      bool plan(String model) => shouldShowModelVisionBadge(
        model,
        true,
        accessType: 'zhipu-account',
        accessMode: 'individual-coding-plan',
      );
      expect(plan('GLM-5.3'), isFalse, reason: '大小写不敏感');
      expect(plan('Glm-5.3'), isFalse);
      expect(plan('glm-5.3x'), isTrue, reason: '不是子串匹配');
      expect(plan('my-glm-5.3'), isTrue, reason: '不是后缀匹配');
      expect(plan('glm-5.3 '), isTrue, reason: '官方不 trim：带空格即不等');
    });
  });

  group('modelSelectionRawOptions（getView 真实 wire 形态）', () {
    test('读出图片能力事实与接入类型/模式/账号族（套餐）', () {
      final raw = _single(
        _view(access: _planAccess(), modelConfig: {
          'enabled': true,
          'properties': _properties(supportsImage: true),
          'optionSpecs': {
            'reasoningLevel': {'values': ['nothink', 'think']},
          },
        }),
      );
      expect(raw['modelSupportsImage'], isTrue);
      expect(raw['modelAccessType'], 'zhipu-account');
      expect(raw['modelAccessMode'], 'individual-coding-plan');
      expect(raw['modelAccessAccountType'], 'bigmodel');
    });

    test('API 渠道：接入类型 api-key，无模式', () {
      final raw = _single(
        _view(
          access: const {'type': 'api-key'},
          modelConfig: {
            'enabled': true,
            'properties': _properties(supportsImage: false),
          },
        ),
      );
      expect(raw['modelSupportsImage'], isFalse);
      expect(raw['modelAccessType'], 'api-key');
      expect(raw.containsKey('modelAccessMode'), isFalse);
    });

    test('能力事实缺失或非布尔=不给事实（键不出现，标签不显示）', () {
      Map<String, dynamic> cfg(Map<String, dynamic>? properties) =>
          properties == null
          ? {'enabled': true}
          : {'enabled': true, 'properties': properties};
      final cases = <String, Map<String, dynamic>>{
        'config 无 properties': cfg(null),
        'properties 无 inputFormat': cfg({'contextWindow': 1}),
        'inputFormat 无 supportsImage': cfg({
          'inputFormat': {'supportsText': true},
        }),
        'supportsImage 为字符串': cfg({
          'inputFormat': {'supportsImage': 'true'},
        }),
        'supportsImage 为数字': cfg({
          'inputFormat': {'supportsImage': 1},
        }),
      };
      for (final e in cases.entries) {
        final raw = _single(
          _view(access: _planAccess(), modelConfig: e.value),
        );
        expect(
          raw.containsKey('modelSupportsImage'),
          isFalse,
          reason: e.key,
        );
      }
      // model 无 config。
      expect(
        _single(
          _view(
            access: _planAccess(),
            pid: 'prov-example',
            modelConfig: const {},
          ),
        ).containsKey('modelSupportsImage'),
        isFalse,
      );
    });

    test('既有条目形状不变：value=providerId/modelId、名称、来源、思考档', () {
      final raw = modelSelectionRawOptions({
        'revision': 9,
        'providers': [
          null,
          'not-a-map',
          {
            'providerId': 'prov-a',
            'providerName': 'Provider A',
            'config': null,
            'models': [
              {
                'modelId': 'm1',
                'config': {
                  'optionSpecs': {
                    'reasoningLevel': {'values': ['low', 'high']},
                  },
                },
              },
              'junk',
              {'modelId': '', 'config': null},
              {'config': null},
            ],
          },
          {'providerId': '', 'models': [{'modelId': 'm2'}]},
          {
            // 无 providerName：名称键不出现。
            'providerId': 'prov-b',
            'models': [
              {'modelId': 'z-ai/glm-5.3'},
            ],
          },
        ],
      });
      expect(raw, [
        {
          'value': 'prov-a/m1',
          'name': 'm1',
          'modelProviderId': 'prov-a',
          'modelProviderName': 'Provider A',
          'modelThoughtLevels': ['low', 'high'],
        },
        {'value': 'prov-b/z-ai/glm-5.3', 'name': 'z-ai/glm-5.3',
         'modelProviderId': 'prov-b'},
      ]);
    });

    test('空视图/无 providers/字段类型不符 → 空目录', () {
      expect(modelSelectionRawOptions(null), isEmpty);
      expect(modelSelectionRawOptions(const {}), isEmpty);
      expect(modelSelectionRawOptions(const {'providers': 'x'}), isEmpty);
      expect(modelSelectionRawOptions(const {'providers': <Object>[]}), isEmpty);
    });
  });

  group('ConfigOptionValue 能力字段', () {
    test('toRaw → fromMap 往返保真', () {
      final v = ConfigOptionValue.fromMap(const {
        'value': 'p/m',
        'name': 'm',
        'modelProviderId': 'p',
        'modelAccessType': 'api-key',
        'modelSupportsImage': true,
      });
      final back = ConfigOptionValue.fromMap(v.toRaw());
      expect(back.modelAccessType, 'api-key');
      expect(back.modelSupportsImage, isTrue);

      final plan = ConfigOptionValue.fromMap(const {
        'value': 'p/m',
        'name': 'm',
        'modelAccessType': 'zhipu-account',
        'modelAccessMode': 'team-coding-plan',
        'modelSupportsImage': false,
      });
      final planBack = ConfigOptionValue.fromMap(plan.toRaw());
      expect(planBack.modelAccessType, 'zhipu-account');
      expect(planBack.modelAccessMode, 'team-coding-plan');
      expect(planBack.modelSupportsImage, isFalse);
    });

    test('字段缺席=null（既有目录条目零影响）', () {
      final v = ConfigOptionValue.fromMap(const {'value': 'p/m', 'name': 'm'});
      expect(v.modelSupportsImage, isNull);
      expect(v.modelAccessType, isNull);
      expect(v.toRaw().containsKey('modelSupportsImage'), isFalse);
      expect(v.toRaw().containsKey('modelAccessType'), isFalse);
    });
  });

  test('modelSupportsImageOf：只认布尔', () {
    expect(modelSupportsImageOf({'properties': _properties()}), isTrue);
    expect(
      modelSupportsImageOf({
        'properties': _properties(supportsImage: false),
      }),
      isFalse,
    );
    expect(modelSupportsImageOf(const {}), isNull);
    expect(modelSupportsImageOf(null), isNull);
    expect(modelSupportsImageOf(const {'properties': null}), isNull);
    expect(
      modelSupportsImageOf({
        'properties': {
          'inputFormat': {'supportsImage': 'true'},
        },
      }),
      isNull,
    );
  });
}
