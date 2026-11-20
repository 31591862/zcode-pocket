import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/marketing_client.dart';
import 'package:zcode_pocket/transport/relay_v2.dart'
    show RelayV2AuthRequired;

/// 营销投放/领取客户端（marketing-claim-1）：loopback
/// HttpServer 钉协议契约——信封解析（官方 marketingTouch.ts zod 投影）、
/// claim 数字字符串 code/终态码/文案位置、401/JWT 缺失、上报。
/// 契约出处 官方最新源码快照：marketingTouchService.ts:50-84、
/// bigmodelCodingPlanSubscriptionProvider.ts:340-410。
void main() {
  MarketingApiClient api(
    Uri origin, {
    Future<String?> Function() jwt = _jwtOk,
  }) =>
      MarketingApiClient(
        origin: origin,
        jwtProvider: jwt,
        deviceMid: '0f0b9ee9-3b1c-4a4e-9d2f-6d7c8f9a0b1c',
        locale: 'zh-CN',
        appVersion: '1.0.7-test',
        platform: 'android',
        timeout: const Duration(seconds: 5),
      );

  test('touch：banner 投放解析（按钮文案/plan_id/图资产/头部三件套）',
      () async {
    final hit = <HttpRequest>[];
    final server = await _serve((req, body) {
      hit.add(req);
      return _json({
        'code': 0,
        'msg': 'ok',
        'data': {
          'server_time': 1760000000,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'cmp-300m-flash',
              'priority': 80,
              'resource_position': 'banner',
              'banner': {
                'layout': 'v1',
                'background': {
                  'type': 'image',
                  'image': {
                    'default': {
                      'src': 'https://static.zcode.z.ai/banner.png',
                      'sha256': 'a' * 64,
                    },
                    'dark': {
                      'src': 'https://static.zcode.z.ai/banner-dark.png',
                      'sha256': 'b' * 64,
                    },
                  },
                },
                'buttons': [
                  {
                    'text': {'format': 'plaintext', 'content': '领取'},
                    'action': {
                      'type': 'claim_zcode_plan',
                      'args': {'plan_id': 'plan-glmlite-300m'},
                    },
                  },
                  {
                    'text': {'format': 'plaintext', 'content': '×'},
                    'action': {'type': 'close'},
                  },
                ],
              },
            },
          ],
        },
      });
    });
    final snapshot = await api(server).touch();
    expect(snapshot.serverTimeMs, 1760000000000, reason: '官方秒→毫秒');
    expect(snapshot.deliveries, hasLength(1));
    final d = snapshot.deliveries.first;
    expect(d.campaignId, 'cmp-300m-flash');
    expect(d.position, 'banner');
    expect(d.buttonText, '领取');
    expect(d.claimPlanId, 'plan-glmlite-300m');
    expect(d.claimable, isTrue);
    expect(d.image?.src.toString(), 'https://static.zcode.z.ai/banner.png');
    expect(d.image?.sha256, 'a' * 64);
    expect(d.darkImage?.sha256, 'b' * 64);
    // 请求头契约（marketingTouchService.ts:42-47）。
    final req = hit.single;
    expect(req.headers.value('Authorization'), 'Bearer jwt-x');
    expect(req.headers.value('X-Device-Mid'), isNotNull);
    expect(req.headers.value('X-Client-Language'), 'zh-CN');
    expect(req.headers.value('X-ZCode-App-Version'), '1.0.7-test');
    expect(req.uri.queryParameters['seq'], isNotNull);
    final firstSeq = int.parse(hit.last.uri.queryParameters['seq']!);
    // seq 随调用单调递增（官方 bootRequestSeq 进程级语义——不归零）。
    await api(server).touch();
    expect(
      int.parse(hit.last.uri.queryParameters['seq']!),
      greaterThan(firstSeq),
    );
  });

  test('touch：popup 投放解析 + 坏投放丢弃 + 同位置去重只留首条', () async {
    final server = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              // 坏投放：priority 越界（zod 0-100）→ 整条丢弃。
              'campaign_id': 'bad-1',
              'priority': 101,
              'resource_position': 'popup',
              'popup': _popup('bad-1'),
            },
            {
              'campaign_id': 'pop-1',
              'priority': 50,
              'resource_position': 'popup',
              'popup': _popup('pop-1', title: '限时福利', desc: '今日有效'),
            },
            {
              // 同位置第二条 → 丢弃（官方 positions Set 语义）。
              'campaign_id': 'pop-2',
              'priority': 90,
              'resource_position': 'popup',
              'popup': _popup('pop-2'),
            },
          ],
        },
      });
    });
    final snapshot = await api(server).touch();
    expect(snapshot.deliveries, hasLength(1));
    final d = snapshot.deliveries.first;
    expect(d.campaignId, 'pop-1');
    expect(d.title, '限时福利');
    expect(d.description, '今日有效');
    expect(d.position, 'popup');
  });

  test('touch：非 0 code 按不可重试失败（信封契约）', () async {
    final server = await _serve((req, body) => _json({'code': 403}));
    await expectLater(
      api(server).touch(),
      throwsA(
        isA<MarketingUnavailable>().having(
          (e) => e.retryable,
          'retryable',
          isFalse,
        ),
      ),
    );
  });

  test('claim 成功：code=0+data.plan → 权益清单+msg 文案；头部带 X-Platform',
      () async {
    HttpRequest? hit;
    Map<String, dynamic>? claimBody;
    final server = await _serve((req, body) {
      hit = req;
      claimBody = body;
      return _json({
        'code': 0,
        'msg': '领取成功',
        'data': {
          'server_time': 1760000000000,
          'plan': {
            'user_plan_id': 'up-1',
            'plan_id': 'plan-glmlite-300m',
            'status': 'active',
            'entitlements': [
              {
                'entitlement_id': 'ent-1',
                'show_name': 'GLM-5.3-Flash 300M tokens 额度',
              },
              {'entitlement_id': 'ent-2', 'show_name': ''},
            ],
          },
        },
      });
    });
    final result = await api(server).claim('plan-glmlite-300m');
    expect(result.success, isTrue);
    expect(result.terminal, isFalse);
    expect(result.message, '领取成功');
    // 官方语义保留全部权益（含空 show_name——UI 展示名筛选在控制器做）。
    expect(result.entitlements, hasLength(2));
    expect(result.entitlements.first.showName, 'GLM-5.3-Flash 300M tokens 额度');
    expect(result.entitlements.last.showName, '');
    expect(claimBody!['plan_id'], 'plan-glmlite-300m');
    expect(hit!.headers.value('X-Platform'), 'android');
    expect(hit!.headers.value('Authorization'), 'Bearer jwt-x');
  });

  test('claim 终态失败：数字字符串 code 1001 + data.message 透传', () async {
    final server = await _serve((req, body) {
      return _json({
        'code': '1001',
        'data': {'message': '您已领取过该套餐'},
      });
    });
    final result = await api(server).claim('plan-x');
    expect(result.success, isFalse);
    expect(result.code, 1001, reason: '官方 code 可为数字字符串');
    expect(result.terminal, isTrue, reason: '1001-1005 为终态码');
    expect(result.message, '您已领取过该套餐', reason: '失败文案在 data.message');
  });

  test('claim 非终态失败与 code 缺失（缺失不推断成功）', () async {
    final transient = await _serve(
      (req, body) => _json({
        'code': 500,
        'data': {'message': '系统繁忙'},
      }),
    );
    final r1 = await api(transient).claim('p');
    expect(r1.success, isFalse);
    expect(r1.terminal, isFalse, reason: '500 可重试');
    expect(r1.message, '系统繁忙');

    final noCode = await _serve((req, body) => _json({'data': {}}));
    final r2 = await api(noCode).claim('p');
    expect(r2.success, isFalse);
    expect(r2.code, -1);
  });

  test('claim 传输异常=结果未知（POST 可能已送达）：不可当作未领取', () async {
    // 未监听端口 → SocketException → MarketingUnavailable。
    final api2 = api(Uri.parse('http://127.0.0.1:1'));
    await expectLater(
      api2.claim('p'),
      throwsA(isA<MarketingUnavailable>()),
    );
  });

  test('鉴权：401 与 JWT 缺失均抛 RelayV2AuthRequired（不自愈重试）',
      () async {
    final unauthorized = await _serve(
      (req, body) => _json({'code': 40100, 'msg': 'unauthorized'}, status: 401),
    );
    await expectLater(
      api(unauthorized).touch(),
      throwsA(isA<RelayV2AuthRequired>()),
    );
    final server = await _serve((req, body) => _json({'code': 0, 'data': {}}));
    await expectLater(
      api(server, jwt: () async => null).claim('p'),
      throwsA(isA<RelayV2AuthRequired>()),
    );
  });

  test('reportAction：confirm/cancel 载荷与 code!=0 抛错', () async {
    final bodies = <Map<String, dynamic>>[];
    final recorder = await _serve((req, b) {
      bodies.add(b);
      return _json({'code': 0});
    });
    await api(recorder).reportAction('cmp-1', confirm: true);
    await api(recorder).reportAction('cmp-2', confirm: false);
    expect(bodies, [
      {'campaign_id': 'cmp-1', 'action_type': 'confirm'},
      {'campaign_id': 'cmp-2', 'action_type': 'cancel'},
    ]);

    final failing = await _serve((req, b) => _json({'code': 1}));
    await expectLater(
      api(failing).reportAction('cmp-1', confirm: true),
      throwsA(isA<MarketingUnavailable>()),
    );
  });


  // ---------------- review-1：官方成功判据缺口（审查④高7）。

  test('claim 成功判据三缺档：code=0 但 data/plan 缺失或非对象一律失败',
      () async {
    final cases = <Map<String, dynamic>>[
      {'code': 0},
      {'code': 0, 'data': {}},
      {'code': 0, 'data': {'plan': null}},
      {'code': 0, 'data': {'plan': 'not-an-object'}},
    ];
    for (final payload in cases) {
      final server = await _serve((req, body) => _json(payload));
      final result = await api(server).claim('p');
      expect(result.success, isFalse, reason: '载荷 $payload 不得判成功');
      expect(result.terminal, isFalse);
    }
  });

  test('claim code="0"（字符串成功形态）与整值 double（0.0/1001.0）',
      () async {
    final strServer = await _serve((req, body) => _json({
          'code': '0',
          'msg': '领取成功',
          'data': {
            'plan': {'plan_id': 'p'},
          },
        }));
    final r1 = await api(strServer).claim('p');
    expect(r1.success, isTrue, reason: '数字字符串 "0" 是官方合法成功形态');

    final dblServer = await _serve((req, body) => _json({
          'code': 0.0,
          'msg': '领取成功',
          'data': {
            'plan': {'plan_id': 'p'},
          },
        }));
    final r2 = await api(dblServer).claim('p');
    expect(r2.success, isTrue, reason: 'JSON 0.0（整值 double）按 0 归一');

    final termDbl = await _serve((req, body) => _json({
          'code': 1001.0,
          'data': {'message': '您已领取过该套餐'},
        }));
    final r3 = await api(termDbl).claim('p');
    expect(r3.success, isFalse);
    expect(r3.code, 1001);
    expect(r3.terminal, isTrue);
  });

  // ---------------- review-1：HTTP 状态核（审查①/④高4）。

  test('非 2xx 不读业务字段：403/500 带 code=0 体也按不可用失败', () async {
    final server = await _serve((req, body) => _json({
          'code': 0,
          'data': {
            'plan': {'plan_id': 'p'},
          },
        }, status: 403));
    await expectLater(
      api(server).claim('p'),
      throwsA(isA<MarketingUnavailable>()),
      reason: 'WAF 403 体形如成功信封也不得判领取成功',
    );
    final server500 = await _serve(
      (req, body) => _json({'code': 0}, status: 500),
    );
    await expectLater(
      api(server500).touch(),
      throwsA(isA<MarketingUnavailable>()),
    );
  });

  test('302（不跟随）按瞬态失败；HTML 体按终态失败（非裸 FormatException）',
      () async {
    final redirect = await _serve(
      (req, body) => _json({'code': 0}, status: 302),
    );
    await expectLater(
      api(redirect).touch(),
      throwsA(
        isA<MarketingUnavailable>().having(
          (e) => e.retryable,
          'retryable',
          isTrue, // 官方 touch redirect:error=瞬态失败语义
        ),
      ),
    );
    final rawServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => rawServer.close(force: true));
    rawServer.listen((req) async {
      await utf8.decoder.bind(req).drain();
      req.response.statusCode = 200;
      req.response.write('<html>not json</html>');
      await req.response.close();
    });
    await expectLater(
      api(Uri.parse('http://127.0.0.1:${rawServer.port}')).touch(),
      throwsA(
        isA<MarketingUnavailable>().having(
          (e) => e.retryable,
          'retryable',
          isFalse, // 非法 JSON=终态且被包装（不裸抛 FormatException）
        ),
      ),
    );
  });

  test('claim 已提交后 401 归 MarketingUnavailable（uncertain）；touch 401 归 AuthRequired',
      () async {
    final claimServer = await _serve(
      (req, body) => _json({'code': 40100}, status: 401),
    );
    await expectLater(
      api(claimServer).claim('p'),
      throwsA(isA<MarketingUnavailable>()),
      reason: '官方口径：submitted 后一切异常（含 401）按 uncertain',
    );
    final touchServer = await _serve(
      (req, body) => _json({'code': 40100}, status: 401),
    );
    await expectLater(
      api(touchServer).touch(),
      throwsA(isA<RelayV2AuthRequired>()),
    );
  });

  // ------------- review-1：投放解析收紧（审查①M2/M3//、④中2）。

  test('banner 两个非 close 按钮官方拒收；未知 action 类型整条丢弃',
      () async {
    final server = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'two-cta',
              'priority': 80,
              'resource_position': 'banner',
              'banner': {
                'background': _imageVisual(),
                'buttons': [
                  _button('了解详情', 'navigate', {'page': 'upgrade'}),
                  _button('领取', 'claim_zcode_plan', {'plan_id': 'p-1'}),
                ],
              },
            },
            {
              'campaign_id': 'unknown-action',
              'priority': 90,
              'resource_position': 'popup',
              'popup': _popup('unknown-action', actionType: 'teleport'),
            },
          ],
        },
      });
    });
    final snapshot = await api(server).touch();
    expect(snapshot.deliveries, isEmpty,
        reason: '官方拒收形态不得静默降级为可领取卡');
  });

  test('按钮文案与动作绑定同一按钮（popup 双按钮取 claim 自己的文案）',
      () async {
    final server = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'mixed',
              'priority': 50,
              'resource_position': 'popup',
              'popup': {
                'title': {'format': 'plaintext', 'content': '限时福利'},
                'description': {'format': 'plaintext', 'content': '今日有效'},
                'buttons': [
                  _button('了解详情', 'navigate', {'page': 'rewards'}),
                  _button('立即领取', 'claim_zcode_plan', {'plan_id': 'p-mixed'}),
                ],
              },
            },
          ],
        },
      });
    });
    final snapshot = await api(server).touch();
    final d = snapshot.deliveries.single;
    expect(d.buttonText, '立即领取',
        reason: '审查①H2：文案取 claim 按钮自身，不得取首个非 close');
    expect(d.claimPlanId, 'p-mixed');
  });

  test('video/bundle 视觉跳过退文字卡；hero/banner 图可取', () async {
    final server = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'vid',
              'priority': 50,
              'resource_position': 'popup',
              'popup': {
                'title': {'format': 'plaintext', 'content': '视频活动'},
                'description': {'format': 'plaintext', 'content': '看片领额度'},
                'hero': {
                  'type': 'video',
                  'video': {
                    'src': {
                      'src': 'https://static.zcode.z.ai/v.mp4',
                      'sha256': 'c' * 64,
                    },
                    'fallback': {
                      'src': 'https://static.zcode.z.ai/f.png',
                      'sha256': 'd' * 64,
                    },
                  },
                },
                'buttons': [
                  _button('领取', 'claim_zcode_plan', {'plan_id': 'p-v'}),
                ],
              },
            },
            {
              'campaign_id': 'hero-img',
              'priority': 80,
              'resource_position': 'banner',
              'banner': {
                'background': _imageVisual(),
                'buttons': [
                  _button('领取', 'claim_zcode_plan', {'plan_id': 'p-h'}),
                ],
              },
            },
          ],
        },
      });
    });
    final snapshot = await api(server).touch();
    expect(snapshot.deliveries, hasLength(2), reason: 'popup/banner 各留一条');
    final vid = snapshot.deliveries.firstWhere((d) => d.campaignId == 'vid');
    expect(vid.image, isNull, reason: 'video 变体不取图');
    expect(vid.claimable, isTrue, reason: 'video 投放仍可文字卡领取');
    final banner = snapshot.deliveries.firstWhere((d) => d.campaignId == 'hero-img');
    expect(banner.image, isNotNull);
  });

  test('text.content 非 String 拒收；asset src 带 userinfo 拒收（领取不受影响）',
      () async {
    final badTextServer = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'bad-text',
              'priority': 50,
              'resource_position': 'popup',
              'popup': {
                'title': {'format': 'plaintext', 'content': 123},
                'description': {'format': 'plaintext', 'content': 'x'},
                'buttons': [
                  _button('领取', 'claim_zcode_plan', {'plan_id': 'p'}),
                ],
              },
            },
          ],
        },
      });
    });
    expect(
      (await api(badTextServer).touch()).deliveries,
      isEmpty,
      reason: 'content 非 String 官方 z.string() 拒收',
    );

    final badAssetServer = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            {
              'campaign_id': 'bad-asset',
              'priority': 80,
              'resource_position': 'banner',
              'banner': {
                'background': {
                  'type': 'image',
                  'image': {
                    'default': {
                      'src': 'https://user:pass@static.zcode.z.ai/a.png',
                      'sha256': 'a' * 64,
                    },
                  },
                },
                'buttons': [
                  _button('领取', 'claim_zcode_plan', {'plan_id': 'p'}),
                ],
              },
            },
          ],
        },
      });
    });
    final d = (await api(badAssetServer).touch()).deliveries.single;
    expect(d.image, isNull, reason: '带凭据 URL 官方拒收');
    expect(d.claimable, isTrue, reason: '资产拒收不影响领取能力');
  });

  test('deliveries>32 拒整个信封（官方 zod max(32)，不静默截断）',
      () async {
    final server = await _serve((req, body) {
      return _json({
        'code': 0,
        'data': {
          'server_time': 1,
          'language': 'zh-CN',
          'deliveries': [
            for (var i = 0; i < 33; i++)
              {
                'campaign_id': 'c\$i',
                'priority': 1,
                'resource_position': 'popup',
                'popup': _popup('c\$i'),
              },
          ],
        },
      });
    });
    await expectLater(
      api(server).touch(),
      throwsA(isA<MarketingUnavailable>()),
      reason: '超限是协议漂移信号，须上浮不得截断吞掉',
    );
  });

  test('服务端失败文案截断 ≤300 字符', () async {
    final server = await _serve((req, body) => _json({
          'code': 500,
          'data': {'message': '长' * 1000},
        }));
    final result = await api(server).claim('p');
    expect(result.message.length, lessThanOrEqualTo(301));
    expect(result.message.endsWith('…'), isTrue);
  });

  test('按端点头：claim 不带 X-Device-Mid/X-Client-Language（官方集合）',
      () async {
    HttpRequest? hit;
    final server = await _serve((req, body) {
      hit = req;
      return _json({
        'code': 0,
        'msg': 'ok',
        'data': {
          'plan': {'plan_id': 'p'},
        },
      });
    });
    await api(server).claim('p');
    expect(hit!.headers.value('X-Platform'), 'android');
    expect(hit!.headers.value('X-ZCode-App-Version'), '1.0.7-test');
    expect(hit!.headers.value('X-Device-Mid'), isNull,
        reason: '官方 claim 头集合不含设备头');
    expect(hit!.headers.value('X-Client-Language'), isNull);
    expect(hit!.method, 'POST');
    expect(hit!.uri.path, '/api/v1/zcode-plan/billing/claim');
  });

  test('响应体超 2MiB 的投放图直弃（remote_banner_image 上限）', () async {
    // 与 relay 家族同规格的 4MiB 信封上限由 marketing client 继承；
    // 这里只钉住 touch 大 body 的失败面（不整页 join 进内存）。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      await utf8.decoder.bind(req).drain();
      req.response.statusCode = 200;
      req.response.add(Uint8List(5 * 1024 * 1024));
      await req.response.close().catchError((_) => req.response);
    });
    await expectLater(
      api(Uri.parse('http://127.0.0.1:${server.port}')).touch(),
      throwsA(isA<MarketingUnavailable>()),
    );
  });
}

Future<String?> _jwtOk() async => 'jwt-x';

Map<String, dynamic> _popup(
  String id, {
  String title = '福利',
  String desc = '领取',
  String actionType = 'claim_zcode_plan',
}) =>
    {
      'layout': 'v1',
      'title': {'format': 'plaintext', 'content': title},
      'description': {'format': 'plaintext', 'content': desc},
      'buttons': [
        {
          'text': {'format': 'plaintext', 'content': '领取'},
          'action': {
            'type': actionType,
            'args': {'plan_id': 'plan-$id'},
          },
        },
      ],
    };

typedef _Handler = Map<String, dynamic> Function(
  HttpRequest req,
  Map<String, dynamic> body,
);

Future<Uri> _serve(_Handler handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((req) async {
    final text = await utf8.decoder.bind(req).join();
    final body = text.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(text) as Map).cast<String, dynamic>();
    final payload = handler(req, body);
    final status = payload.remove(_statusKey) as int? ?? 200;
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    await req.response.close();
  });
  return Uri.parse('http://127.0.0.1:${server.port}');
}

const _statusKey = '__status__';

Map<String, dynamic> _json(Map<String, dynamic> map, {int status = 200}) => {
      ...map,
      '$_statusKey': status,
    };

Map<String, dynamic> _imageVisual() => {
      'type': 'image',
      'image': {
        'default': {
          'src': 'https://static.zcode.z.ai/banner.png',
          'sha256': 'a' * 64,
        },
      },
    };

Map<String, dynamic> _button(
  String text,
  String actionType,
  Map<String, dynamic> args,
) =>
    {
      'text': {'format': 'plaintext', 'content': text},
      'action': {'type': actionType, 'args': args},
    };
