// 新增四家外部额度适配器回归（智谱 GLM Coding Plan 直连 / 小米 MiMo
// Token Plan / Ollama Cloud / Command Code）：响应解析、鉴权头形态、
// 「HTTP 200 + 业务码 401」的呈现、结构不符降级。全部走注入的假 HTTP，
// 不触真实网络。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/external_quota.dart';

typedef _Reply = ({int statusCode, String body});

class _Capture {
  Uri? uri;
  Map<String, String> headers = const {};
  _Reply reply;
  _Capture(this.reply);

  Future<_Reply> get(Uri uri, Map<String, String> headers) async {
    this.uri = uri;
    this.headers = headers;
    return reply;
  }
}

final _now = DateTime(2026, 11, 25, 22, 0);

Future<ExternalQuotaSnapshot> _fetch(
  ExternalQuotaAdapter adapter, {
  required String body,
  int statusCode = 200,
  _Capture? capture,
  String baseUrl = '',
}) async {
  final cap = capture ?? _Capture((statusCode: statusCode, body: body));
  final client = ExternalQuotaClient(httpGet: cap.get, now: () => _now);
  return client.fetchOne(
    adapter,
    ExternalQuotaProviderConfig(
      providerId: adapter.id,
      apiKey: 'sk-test-key',
      baseUrl: baseUrl,
    ),
  );
}

void main() {
  group('注册表', () {
    test('六家适配器按展示顺序登记，id 唯一', () {
      final ids = kExternalQuotaAdapters.map((a) => a.id).toList();
      expect(ids, [
        'kimi_coding',
        'opencode_go',
        'zhipu_coding',
        'mimo_token_plan',
        'ollama_cloud',
        'command_code',
      ]);
      expect(ids.toSet().length, ids.length);
      for (final id in ids) {
        expect(externalQuotaAdapterById(id)?.id, id);
      }
    });

    test('接口地址全部为 HTTPS 且落在各自官方域名', () {
      final expected = {
        'zhipu_coding':
            'https://open.bigmodel.cn/api/monitor/usage/quota/limit',
        'mimo_token_plan':
            'https://token-plan-cn.xiaomimimo.com/v1/platform/token_plan',
        'ollama_cloud': 'https://ollama.com/api/balance',
        'command_code': 'https://api.commandcode.ai/alpha/billing/credits',
      };
      for (final entry in expected.entries) {
        final adapter = externalQuotaAdapterById(entry.key)!;
        expect(resolveExternalQuotaUri(adapter).toString(), entry.value);
      }
    });
  });

  group('智谱 GLM Coding Plan 直连', () {
    const adapter = ZhipuCodingQuotaAdapter();
    final resetMs = DateTime.utc(2026, 11, 26, 2).millisecondsSinceEpoch;
    final okBody = jsonEncode({
      'code': 200,
      'success': true,
      'data': {
        'level': 'Pro',
        'limits': [
          {
            'type': 'TOKENS_LIMIT',
            'unit': 3,
            'number': 5,
            'percentage': 42,
            'nextResetTime': resetMs,
          },
          {
            'type': 'TOKENS_LIMIT',
            'unit': 6,
            'number': 7,
            'percentage': 88.5,
            'nextResetTime': resetMs + 86400000,
          },
          {'type': 'TIME_LIMIT', 'unit': 1, 'percentage': 10},
        ],
      },
    });

    test('解析 5 小时窗口与每周额度：percentage=已用占比，重置时间取毫秒时间戳', () async {
      final snap = await _fetch(adapter, body: okBody);
      expect(snap.ok, isTrue);
      expect(snap.windows.map((w) => w.label), ['5 小时窗口', '每周额度']);
      expect(snap.windows[0].usedPercent, 42.0);
      expect(snap.windows[0].remainingPercent, 58.0);
      expect(snap.windows[1].usedPercent, 88.5);
      expect(
        snap.windows[0].resetAt?.toUtc(),
        DateTime.utc(2026, 11, 26, 2),
      );
      expect(snap.windows[0].resetLabel, isNotEmpty);
    });

    test('鉴权头直接放 key，不加 Bearer 前缀', () async {
      final cap = _Capture((statusCode: 200, body: okBody));
      await _fetch(adapter, body: okBody, capture: cap);
      expect(cap.headers['Authorization'], 'sk-test-key');
      expect(cap.headers['Accept-Language'], 'en-US,en');
    });

    test('HTTP 200 + 业务码 401 → 按 Key 失效呈现并带鉴权提示', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'code': 401,
          'msg': 'token expired or incorrect',
          'success': false,
        }),
      );
      expect(snap.ok, isFalse);
      expect(snap.error, 'API Key 失效或未授权（401）');
      expect(snap.hint, adapter.authHint);
    });

    test('其他业务错误 / 无有效 limits / 非对象 → 格式无法识别', () async {
      for (final body in [
        jsonEncode({'code': 500, 'msg': 'server error', 'success': false}),
        jsonEncode({'success': true, 'data': {'limits': []}}),
        jsonEncode({'success': true, 'data': {'limits': 'bad'}}),
        '[]',
      ]) {
        final snap = await _fetch(adapter, body: body);
        expect(snap.ok, isFalse, reason: body);
        expect(snap.error, '返回数据格式无法识别', reason: body);
      }
    });

    test('国际版账号可把接口地址改为 api.z.ai（同路径）', () async {
      final cap = _Capture((statusCode: 200, body: okBody));
      final snap = await _fetch(
        adapter,
        body: okBody,
        capture: cap,
        baseUrl: 'https://api.z.ai',
      );
      expect(snap.ok, isTrue);
      expect(
        cap.uri.toString(),
        'https://api.z.ai/api/monitor/usage/quota/limit',
      );
    });
  });

  group('小米 MiMo Token Plan', () {
    const adapter = MimoTokenPlanQuotaAdapter();

    test('由已用积分折算本期额度，周期时间按 UTC 无时区形态解析', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'quota': {
            'total_credits': 500,
            'used_credits': 125,
            'remaining_credits': 375,
          },
          'period': {'end_at': '2026-12-20 15:59:59'},
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.single.label, '本期额度');
      expect(snap.windows.single.usedPercent, 25.0);
      expect(snap.windows.single.remainingPercent, 75.0);
      expect(
        snap.windows.single.resetAt?.toUtc(),
        DateTime.utc(2026, 12, 20, 15, 59, 59),
      );
      expect(snap.notes, ['本期积分 剩余 375 / 500']);
    });

    test('缺已用积分时用总额减剩余倒推', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'quota': {'total_credits': 200, 'remaining_credits': 50},
          'period': {'end_at': '2027-01-01 00:00:00'},
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.single.usedPercent, 75.0);
      expect(snap.notes, ['本期积分 剩余 50 / 200']);
    });

    test('缺 quota / 总额为 0 / 缺周期 → 格式无法识别', () async {
      for (final body in [
        jsonEncode({'foo': 1}),
        jsonEncode({
          'quota': {'total_credits': 0, 'used_credits': 0},
        }),
        jsonEncode({
          'quota': {'total_credits': 100},
        }),
      ]) {
        final snap = await _fetch(adapter, body: body);
        expect(snap.ok, isFalse, reason: body);
        expect(snap.error, '返回数据格式无法识别', reason: body);
      }
    });

    test('鉴权头为标准 Bearer', () async {
      final cap = _Capture((statusCode: 200, body: '{}'));
      await _fetch(adapter, body: '{}', capture: cap);
      expect(cap.headers['Authorization'], 'Bearer sk-test-key');
    });
  });

  group('Ollama Cloud', () {
    const adapter = OllamaCloudQuotaAdapter();

    test('有月度美元额度时折成每月额度一档', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'included': {
            'balance_usd': 15,
            'allowance_usd': 20,
            'period': {'until': '2026-11-30T23:59:59Z'},
          },
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.single.label, '每月额度');
      expect(snap.windows.single.usedPercent, 25.0);
      expect(snap.windows.single.resetAt?.toUtc(), DateTime.utc(2026, 11, 30, 23, 59, 59));
    });

    test('无月度额度时取会话与周两个窗口的剩余百分比', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'included': {
            'session': {'remaining_percent': 62, 'resets_at': '2026-11-26T03:00:00Z'},
            'weekly': {'remaining_percent': 31.5},
          },
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.map((w) => w.label), ['5 小时窗口', '每周额度']);
      expect(snap.windows[0].usedPercent, 38.0);
      expect(snap.windows[1].remainingPercent, 31.5);
      expect(snap.windows[1].resetAt, isNull);
    });

    test('缺 included / 无有效数据 → 格式无法识别', () async {
      for (final body in [
        jsonEncode({'balance_usd': 1}),
        jsonEncode({'included': 'bad'}),
        jsonEncode({'included': {'session': 'bad'}}),
      ]) {
        final snap = await _fetch(adapter, body: body);
        expect(snap.ok, isFalse, reason: body);
        expect(snap.error, '返回数据格式无法识别', reason: body);
      }
    });
  });

  group('Command Code', () {
    const adapter = CommandCodeQuotaAdapter();

    final windows = {
      'fiveHour': {'used': 30, 'cap': 120, 'resetAt': '2026-11-26T02:00:00Z'},
      'weekly': {'used': 900, 'cap': 3000},
    };

    test('由已用/上限折算 5 小时窗口与每周额度（根层 windowLimits）', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'credits': {'monthlyCredits': 100},
          'windowLimits': {'limited': true, ...windows},
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.map((w) => w.label), ['5 小时窗口', '每周额度']);
      expect(snap.windows[0].usedPercent, 25.0);
      expect(snap.windows[1].usedPercent, 30.0);
      expect(snap.windows[0].resetAt?.toUtc(), DateTime.utc(2026, 11, 26, 2));
    });

    test('兼容 windowLimits 嵌在 credits 里的形态', () async {
      final snap = await _fetch(
        adapter,
        body: jsonEncode({
          'credits': {'windowLimits': windows},
        }),
      );
      expect(snap.ok, isTrue);
      expect(snap.windows.length, 2);
    });

    test('缺 windowLimits / 上限为 0 → 格式无法识别', () async {
      for (final body in [
        jsonEncode({'credits': {}}),
        jsonEncode({
          'windowLimits': {
            'fiveHour': {'used': 1, 'cap': 0},
          },
        }),
      ]) {
        final snap = await _fetch(adapter, body: body);
        expect(snap.ok, isFalse, reason: body);
        expect(snap.error, '返回数据格式无法识别', reason: body);
      }
    });
  });

  test('既有 Bearer 平台不受影响：Kimi 仍带 Bearer 前缀', () async {
    const kimi = KimiCodingQuotaAdapter();
    expect(kimi.useBearerAuth, isTrue);
    final cap = _Capture((
      statusCode: 200,
      body: jsonEncode({
        'usages': {
          'limit_5h': {'used_ratio': 0.25, 'reset_time': '2026-11-26T02:00:00Z'},
        },
      }),
    ));
    final snap = await _fetch(kimi, body: '', capture: cap);
    expect(snap.ok, isTrue);
    expect(cap.headers['Authorization'], 'Bearer sk-test-key');
    expect(cap.headers.containsKey('Accept-Language'), isFalse);
  });
}
