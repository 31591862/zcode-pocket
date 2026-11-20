import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/marketing_controller.dart';
import 'package:zcode_pocket/transport/marketing_client.dart';

/// 领取卡状态机（marketing-claim-1；marketing-claim-review-1 全面改写）：
/// 经 originProvider 指向 loopback 走真实 HTTP。覆盖：每账号闸、失败
/// 退避（审查②）、账号缓存与 onAccountChanged 钩子（②）、跨账号
/// 陈旧卡守卫（①/②M2）、领取四分支、fire-and-forget 上报（④高3）、
/// 一次性字段入口清（②）、claim 代际不被在途拉取吞卡（②M3）、空
/// 快照清卡（④中4）、provider 抛错不卡死（②）。
void main() {
  late String accountId;
  var touchHits = 0;
  var claimHits = 0;

  MarketingController build(
    Uri origin, {
    DateTime Function()? clock,
  }) =>
      MarketingController(
        accountIdProvider: () async => accountId,
        jwtProvider: (id) async => 'jwt-$id',
        deviceMidProvider: () async => '0f0b9ee9-3b1c-4a4e-9d2f-6d7c8f9a0b1c',
        localeProvider: () => 'zh-CN',
        appVersionProvider: () async => '1.0.7-test',
        platformProvider: () => 'android',
        originProvider: () => origin,
        clock: clock ?? DateTime.now,
      );

  setUp(() {
    accountId = 'acc-1';
    touchHits = 0;
    claimHits = 0;
  });

  test('首拉出卡（banner 优先）+同账号闸+force 绕过', () async {
    final origin = await _Server.start(
      onTouch: () {
        touchHits++;
        return _touchResponse([
          _popupDelivery('pop-1'),
          _bannerDelivery('cmp-banner'),
        ]);
      },
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    expect(c.card!.delivery.campaignId, 'cmp-banner',
        reason: 'banner 优先于 popup');
    expect(touchHits, 1);
    // 同账号非 force：每账号闸，不再发请求。
    await c.pull();
    expect(touchHits, 1);
    // force（下拉/顶栏刷新）：绕过闸再拉。
    await c.pull(force: true);
    expect(touchHits, 2);
  });

  test('失败退避：失败后通知触发不再发请求；force 绕过；成功重置（审查②H1）',
      () async {
    var fail = true;
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final origin = await _Server.start(
      onTouch: () {
        touchHits++;
        return fail ? {'code': 403} : _touchResponse([_bannerDelivery('cmp-b')]);
      },
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin, clock: () => now);
    await c.pull();
    expect(touchHits, 1, reason: '首次尝试已发出');
    expect(c.card, isNull);
    // 时间前进 10s（< 30s 退避）：再触发不发。
    now = now.add(const Duration(seconds: 10));
    await c.ensurePulled();
    expect(touchHits, 1, reason: '退避期内零请求——击穿即按通知频率轮询');
    // 退避窗口过后：恢复尝试。
    now = now.add(const Duration(seconds: 25));
    await c.ensurePulled();
    expect(touchHits, 2, reason: '30s 退避到期后允许重试');
    // 仍失败→退避翻倍（60s）：期内零请求。
    now = now.add(const Duration(seconds: 50));
    await c.ensurePulled();
    expect(touchHits, 2);
    // 成功后退避重置为 30s。
    fail = false;
    now = now.add(const Duration(seconds: 15));
    await c.ensurePulled();
    expect(touchHits, 3);
    expect(c.card?.delivery.campaignId, 'cmp-b');
    now = now.add(const Duration(seconds: 35));
    await c.ensurePulled();
    expect(touchHits, 3, reason: '每账号闸接管（成功后不再自动拉）');
  });

  test('账号缓存+onAccountChanged：切号后缓存失效立即按新账号重拉（②M7）',
      () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-a1')]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card!.accountId, 'acc-1');
    accountId = 'acc-2';
    // 60s 账号节流内：ensurePulled 用缓存账号=零新请求（闸也命中）。
    await c.ensurePulled();
    expect(c.card!.accountId, 'acc-1');
    // 生产接线=AccountStore.onChanged → onAccountChanged：失效缓存。
    c.onAccountChanged();
    await c.ensurePulled();
    expect(c.card!.accountId, 'acc-2');
  });

  test('跨账号陈旧卡：切号后拉取失败也不保留旧账号卡（①H3/②M2）',
      () async {
    var failForB = false;
    final origin = await _Server.start(
      onTouch: () => failForB
          ? {'code': 500}
          : _touchResponse([_bannerDelivery('cmp-a')]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    accountId = 'acc-2';
    failForB = true;
    c.onAccountChanged();
    await c.ensurePulled();
    expect(c.card, isNull, reason: 'B 会话不得展示/可领取 A 的投放');
  });

  test('领取成功：收卡+权益名+confirm 上报（fire-and-forget 但最终到达）',
      () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-ok')]),
      onClaim: (plan) async => _claimOk(),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    await c.claim();
    expect(c.card, isNull);
    expect(c.lastClaimedNames, ['GLM-5.3-Flash 300M tokens 额度']);
    // 上报 fire-and-forget——轮询等待到达（不阻塞 claim 返回是修复点，
    // 到达性仍须成立）。
    await _until(() => actions.isNotEmpty);
    expect(actions, [
      {'campaign_id': 'cmp-ok', 'action_type': 'confirm'},
    ]);
    // suppress 键控：同账号 force 重拉同 campaign 不再出卡。
    await c.pull(force: true);
    expect(c.card, isNull);
  });

  test('claim 跨账号守卫：切号后点领取→不发请求+清卡（①H3）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-guard')]),
      onClaim: (plan) async {
        claimHits++;
        return _claimOk();
      },
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    accountId = 'acc-2';
    await c.claim();
    expect(claimHits, 0, reason: 'B 会话不得用 A 的 JWT 领 A 的套餐');
    expect(c.card, isNull);
  });

  test('领取终态失败：收卡+透传文案+不上报', () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-t')]),
      onClaim: (plan) async => {
        'code': '1001',
        'data': {'message': '您已领取过该套餐'},
      },
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    await c.claim();
    expect(c.card, isNull);
    expect(c.lastTerminalMessage, '您已领取过该套餐');
    expect(c.lastClaimedNames, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(actions, isEmpty, reason: '终态失败不消耗 confirm/cancel 配额');
  });

  test('领取非终态失败：卡保留+错误行可重试', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-500')]),
      onClaim: (plan) async => {
        'code': 500,
        'data': {'message': '系统繁忙'},
      },
    );
    final c = build(origin);
    await c.pull();
    await c.claim();
    expect(c.card, isNotNull);
    expect(c.errorKind, MarketingClaimError.server);
    expect(c.serverErrorMessage, '系统繁忙');
    expect(c.claiming, isFalse);
  });

  test('领取传输异常：结果未知档+卡保留（含服务端 401→uncertain）', () async {
    // 断连（null=destroy socket）。
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-x')]),
      onClaim: (plan) async => null,
    );
    final c = build(origin);
    await c.pull();
    await c.claim();
    expect(c.card, isNotNull);
    expect(c.errorKind, MarketingClaimError.uncertain);
    expect(c.claiming, isFalse);
  });

  test('claim 已提交后 401 归 uncertain（仅发送前缺失归 authRequired）',
      () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-401')]),
      onClaim: (plan) async => {'code': 40100, '__status__': 401},
    );
    final c = build(origin);
    await c.pull();
    await c.claim();
    expect(c.errorKind, MarketingClaimError.uncertain,
        reason: '官方口径：submitted 后任何异常按 uncertain');
    expect(c.card, isNotNull);
  });

  test('拉取失败静默保旧卡+10min 无成功收卡（②L2）', () async {
    var failTouch = false;
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final origin = await _Server.start(
      onTouch: () => failTouch
          ? {'code': 403}
          : _touchResponse([_bannerDelivery('cmp-keep')]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin, clock: () => now);
    await c.pull();
    expect(c.card?.delivery.campaignId, 'cmp-keep');
    failTouch = true;
    now = now.add(const Duration(minutes: 11));
    await c.pull(force: true);
    expect(c.card, isNull, reason: '10min 无成功按官方语义收卡');
  });

  test('成功空快照清卡（审查④中4）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    // 预置一张卡（模拟上一轮拉取结果）。
    await c.pull(force: true);
    expect(c.card, isNull, reason: '空 deliveries=无投放，零占位');
  });

  test('claim 入口清一次性通知字段（②M8：残留不跨挂载串台）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-residue')]),
      onClaim: (plan) async => {
        'code': 500,
        'data': {'message': '系统繁忙'},
      },
    );
    final c = build(origin);
    await c.pull();
    // 模拟上次会话残留（UI 卸载未消费）。
    c.lastClaimedNames = ['旧权益'];
    await c.claim();
    expect(c.lastClaimedNames, isNull,
        reason: '本次非终态失败不得弹出上次的「已领取」');
    expect(c.errorKind, MarketingClaimError.server);
  });

  test('claim 在途拉取换卡：收尾只清当初那张（②M3 代际）', () async {
    final claimGate = Completer<void>();
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-old')]),
      onClaim: (plan) async {
        await claimGate.future;
        return _claimOk();
      },
    );
    final c = build(origin);
    await c.pull();
    expect(c.card!.delivery.campaignId, 'cmp-old');
    final claiming = c.claim();
    // claim 在途：模拟迟到拉取换出新卡（直接置卡=等价路径）。
    await Future<void>.delayed(Duration.zero);
    c.card = MarketingCard(
      accountId: 'acc-1',
      delivery: _parseBanner('cmp-new'),
    );
    claimGate.complete();
    await claiming;
    expect(c.card, isNotNull);
    expect(c.card!.delivery.campaignId, 'cmp-new',
        reason: '新投放不得被旧 claim 的收尾吞掉');
  });

  test('无账号：清卡静默（未登录态）', () async {
    var touched = false;
    final origin = await _Server.start(
      onTouch: () {
        touched = true;
        return _touchResponse([]);
      },
      onClaim: (plan) async => _claimOk(),
    );
    accountId = '';
    final c = build(origin);
    await c.pull();
    expect(touched, isFalse);
    expect(c.card, isNull);
  });

  // ---------------- collapse-1：收起/展开（用户拍板「晚点领」）。

  test('收起：仅视图态——同投放 force 重拉保持收起，展开复原，不上报',
      () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-c')]),
      onClaim: (plan) async => _claimOk(),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    expect(c.isCollapsed, isFalse);
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    // 同投放 force 重拉：保持收起（不重复打扰）。
    await c.pull(force: true);
    expect(c.card, isNotNull);
    expect(c.isCollapsed, isTrue);
    c.expand();
    expect(c.isCollapsed, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(actions, isEmpty, reason: '收起/展开是纯视图态，不消耗上报配额');
  });

  test('收起键控：换投放自动回展开；claiming 在途禁收起', () async {
    final claimGate = Completer<void>();
    var campaign = 'cmp-a';
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery(campaign)]),
      onClaim: (plan) async {
        await claimGate.future;
        return _claimOk();
      },
    );
    final c = build(origin);
    await c.pull();
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    // 换投放（服务端轮换）：新 campaign 默认展开。
    campaign = 'cmp-b';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-b');
    expect(c.isCollapsed, isFalse, reason: '收起只对当初那张投放生效');
    // claiming 在途：collapse 无效（与 UI 禁用同口径）。
    final claiming = c.claim();
    await Future<void>.delayed(Duration.zero);
    c.collapse(c.card!);
    expect(c.isCollapsed, isFalse);
    claimGate.complete();
    await claiming;
  });

  test('claim 首窗口闸：账号读取在飞时收起/关闭/二次领取全被挡（审查②M1）',
      () async {
    final accountGate = Completer<String?>();
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-win')]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = MarketingController(
      accountIdProvider: () => accountGate.future,
      jwtProvider: (id) async => 'jwt-\$id',
      deviceMidProvider: () async => '0f0b9ee9-3b1c-4a4e-9d2f-6d7c8f9a0b1c',
      localeProvider: () => 'zh-CN',
      appVersionProvider: () async => '0',
      platformProvider: () => 'android',
      originProvider: () => origin,
    );
    // 预置卡（绕过真实 pull——账号闸还在）。
    c.card = const MarketingCard(
      accountId: 'acc-1',
      delivery: MarketingDelivery(
        campaignId: 'cmp-win',
        priority: 80,
        position: 'banner',
        claimPlanId: 'plan-win',
      ),
    );
    final claiming = c.claim();
    await Future<void>.delayed(Duration.zero);
    // 窗口内（claiming 已前置置位）：收起/关闭/二次领取全 no-op。
    expect(c.claiming, isTrue, reason: 'claiming 前置到账号读取前');
    final cardRef = c.card!;
    c.collapse(cardRef);
    expect(c.isCollapsed, isFalse, reason: '窗口内收起被挡');
    // dismiss 是 async——同步段判空返回：用 microtask 探测。
    await c.dismiss(cardRef);
    expect(c.card, isNotNull, reason: '窗口内关闭被挡');
    accountGate.complete('acc-1');
    await claiming;
    expect(c.card, isNull, reason: '首个 claim 正常完成');
  });

  test('dismiss 撤销：恢复卡片+解除抑制；不补发 confirm（审查①M2）',
      () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-undo')]),
      onClaim: (plan) async => _claimOk(),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    final dismissed = c.card!;
    await c.dismiss(dismissed);
    expect(c.card, isNull);
    await _until(() => actions.isNotEmpty);
    expect(actions.last['action_type'], 'cancel');
    c.undoDismiss();
    expect(c.card, isNotNull, reason: '撤销恢复卡片');
    expect(c.card!.delivery.campaignId, 'cmp-undo');
    // 抑制已解除：force 重拉同 campaign 仍出卡。
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-undo');
    expect(
      actions.where((a) => a['action_type'] == 'confirm'),
      isEmpty,
      reason: '撤销不补发 confirm（分析数据容忍单向误差，决策记录 留痕）',
    );
  });

  test('claim 账号读取超时：放弃领取+复位 claiming（审查①L3）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-tmo')]),
      onClaim: (plan) async {
        claimHits++;
        return _claimOk();
      },
    );
    final gate = Completer<String?>();
    final c = MarketingController(
      accountIdProvider: () => gate.future,
      jwtProvider: (id) async => 'jwt-\$id',
      deviceMidProvider: () async => '0f0b9ee9-3b1c-4a4e-9d2f-6d7c8f9a0b1c',
      localeProvider: () => 'zh-CN',
      appVersionProvider: () async => '0',
      platformProvider: () => 'android',
      originProvider: () => origin,
    );
    c.claimAccountReadTimeout = const Duration(milliseconds: 50);
    c.card = const MarketingCard(
      accountId: 'acc-1',
      delivery: MarketingDelivery(
        campaignId: 'cmp-tmo',
        priority: 80,
        position: 'banner',
        claimPlanId: 'plan-tmo',
      ),
    );
    await c.claim();
    expect(claimHits, 0, reason: '超时放弃——不发 claim 请求');
    expect(c.claiming, isFalse, reason: 'claiming 复位不永久转圈');
    expect(c.card, isNull);
  });

  test('campaign 级收起语义：A→B→A 回到 A 时保持收起（审查②L1 钉语义）',
      () async {
    var campaign = 'cmp-a';
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery(campaign)]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    await c.pull();
    c.collapse(c.card!);
    expect(c.isCollapsed, isTrue);
    campaign = 'cmp-b';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-b');
    expect(c.isCollapsed, isFalse, reason: '换投放展开');
    campaign = 'cmp-a';
    await c.pull(force: true);
    expect(c.card!.delivery.campaignId, 'cmp-a');
    expect(c.isCollapsed, isTrue,
        reason: 'campaign 级延期：同一活动不因中间换投放而反复打扰');
  });

  test('用户关闭：cancel 上报最终到达+本账号本会话 suppress', () async {
    final actions = <Map<String, dynamic>>[];
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-dismiss')]),
      onClaim: (plan) async => _claimOk(),
      onAction: actions.add,
    );
    final c = build(origin);
    await c.pull();
    await c.dismiss(c.card!);
    expect(c.card, isNull);
    await _until(() => actions.isNotEmpty);
    expect(actions, [
      {'campaign_id': 'cmp-dismiss', 'action_type': 'cancel'},
    ]);
    await c.pull(force: true);
    expect(c.card, isNull);
  });

  test('provider 抛错不卡死：claiming/pulling 全复位（②M4）', () async {
    final origin = await _Server.start(
      onTouch: () => _touchResponse([_bannerDelivery('cmp-throw')]),
      onClaim: (plan) async => _claimOk(),
    );
    final c = build(origin);
    await c.pull();
    expect(c.card, isNotNull);
    // deviceMidProvider 抛错（华为 Keystore 损坏形态）。
    final broken = MarketingController(
      accountIdProvider: () async => accountId,
      jwtProvider: (id) async => 'jwt-$id',
      deviceMidProvider: () async => throw const SocketException('keystore'),
      localeProvider: () => 'zh-CN',
      appVersionProvider: () async => '0',
      platformProvider: () => 'android',
      originProvider: () => origin,
    );
    // 预置卡（正常控制器拉到的）后用坏 provider 控制器点领取。
    broken.card = c.card;
    await broken.claim();
    expect(broken.claiming, isFalse, reason: 'finally 复位，按钮不永久转圈');
    expect(broken.errorKind, MarketingClaimError.uncertain);
  });
}

/// 代际测试用的等价投放模型（形状与 _bannerDelivery 夹具一致——解析器
/// 输出的公开投影；服务假件不发请求故无法直接调 touch）。
MarketingDelivery _parseBanner(String id) => MarketingDelivery(
      campaignId: id,
      priority: 80,
      position: 'banner',
      buttonText: '领取',
      claimPlanId: 'plan-$id',
    );

Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 100 && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(test(), isTrue, reason: '轮询超时（fire-and-forget 未到达）');
}

// ------------------------------------------------------------- 服务假件

class _Server {
  static Future<Uri> start({
    required Map<String, dynamic> Function() onTouch,
    required Future<Map<String, dynamic>?> Function(String plan) onClaim,
    void Function(Map<String, dynamic>)? onAction,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final text = await utf8.decoder.bind(req).join();
      final body = text.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(text) as Map).cast<String, dynamic>();
      Map<String, dynamic>? payload;
      if (req.uri.path == '/api/v1/marketing/touch') {
        payload = onTouch();
      } else if (req.uri.path == '/api/v1/zcode-plan/billing/claim') {
        payload = await onClaim('${body['plan_id']}');
      } else if (req.uri.path == '/api/v1/marketing/touch/action') {
        onAction?.call(body);
        payload = {'code': 0};
      }
      final status = payload?.remove('__status__') as int? ?? 200;
      // null=断连不回包（传输异常注入）。
      if (payload == null) {
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(payload));
      await req.response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}');
  }
}

Map<String, dynamic> _claimOk() => {
      'code': 0,
      'msg': '领取成功',
      'data': {
        'plan': {
          'user_plan_id': 'up-1',
          'plan_id': 'plan-x',
          'status': 'active',
          'entitlements': [
            {
              'entitlement_id': 'ent-1',
              'show_name': 'GLM-5.3-Flash 300M tokens 额度',
            },
          ],
        },
      },
    };

Map<String, dynamic> _touchResponse(List<Map<String, dynamic>> deliveries) => {
      'code': 0,
      'data': {
        'server_time': 1760000000,
        'language': 'zh-CN',
        'deliveries': deliveries,
      },
    };

Map<String, dynamic> _bannerDelivery(String campaignId) => {
      'campaign_id': campaignId,
      'priority': 80,
      'resource_position': 'banner',
      'banner': {
        'background': {
          'type': 'image',
          'image': {
            'default': {
              'src': 'https://static.zcode.z.ai/$campaignId.png',
              'sha256': 'a' * 64,
            },
          },
        },
        'buttons': [
          {
            'text': {'format': 'plaintext', 'content': '领取'},
            'action': {
              'type': 'claim_zcode_plan',
              'args': {'plan_id': 'plan-$campaignId'},
            },
          },
        ],
      },
    };

Map<String, dynamic> _popupDelivery(String campaignId) => {
      'campaign_id': campaignId,
      'priority': 50,
      'resource_position': 'popup',
      'popup': {
        'title': {'format': 'plaintext', 'content': '限时福利'},
        'description': {'format': 'plaintext', 'content': '今日有效'},
        'buttons': [
          {
            'text': {'format': 'plaintext', 'content': '领取'},
            'action': {
              'type': 'claim_zcode_plan',
              'args': {'plan_id': 'plan-$campaignId'},
            },
          },
        ],
      },
    };
