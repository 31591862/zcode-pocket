/// 官方多账号额度直连与缓存引擎：
///
/// 1. **GLM Start Plan / 福利包直连（[OfficialStartPlanDirectClient]）**：
///    对照桌面端 `zaiStartPlanBilling.ts` + `bigmodelUsageQuotaProvider.ts` 实证，
///    Start Plan 余额接口 `GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance`
///    仅需手机已存的 `zcodejwttoken`（`Authorization: Bearer <jwt>`），不依赖桌面在线、
///    无需新建中继连接，离线或非活跃账号也能实时查到夜间 3 亿 GLM-5.3-Flash 等福利包。
/// 2. **GLM Coding Plan 本地摘要缓存（[CachedOfficialQuota]）**：
///    Coding Plan 需 BigModel/Z.AI 业务凭据（仅在桌面端），因此严格守电量红线：
///    仅在已有在线电脑 bridge 时实时拉取并落本机摘要缓存，离线账号只读最近缓存快照
///    （展示灰点与 `缓存于 XX 分钟前`），绝不为查额度偷偷建链或唤醒离线电脑。
/// 3. **安全与隐私红线**：
///    仅允许干净 HTTPS 端点、禁自动重定向防 JWT 泄露、响应上限 256KB、超时强关
///    `HttpClient`、错误信息绝不回显 JWT；缓存仅存非敏感额度摘要，不含任何凭据或身份信息。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'external_quota.dart';
import 'l10n.dart';
import 'usage_format.dart';

/// 官方 Start Plan 余额直连端点（与桌面端 `zcodeEndpoint.ts:384` 一致）。
final Uri kOfficialStartPlanBalanceUri = Uri.parse(
  'https://zcode.z.ai/api/v1/zcode-plan/billing/balance?app_version=4.0.0',
);

/// 本地 Coding Plan 缓存最大保留账号数（防止异常场景无限增长）。
const int kMaxCachedOfficialQuotaAccounts = 10;

/// 单个被缓存的官方配额窗口摘要（仅存非敏感展示字段）。
class CachedQuotaWindow {
  const CachedQuotaWindow({
    required this.label,
    required this.remainingPercent,
    this.resetAtMs,
    this.colorSlot = 0,
  });

  final String label;
  final double remainingPercent;
  final int? resetAtMs;

  /// 图表调色板槽位（0=5h蓝 / 1=周绿 / 2=月工具紫 / 5=MCP青）。
  final int colorSlot;

  Map<String, dynamic> toJson() => {
    'label': label,
    'remainingPercent': remainingPercent,
    if (resetAtMs != null) 'resetAtMs': resetAtMs,
    'colorSlot': colorSlot,
  };

  static CachedQuotaWindow? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final label = raw['label'];
    final pct = raw['remainingPercent'];
    if (label is! String || label.trim().isEmpty) return null;
    if (pct is! num || !pct.isFinite) return null;
    final rawReset = raw['resetAtMs'];
    final resetAtMs = rawReset is num && rawReset.isFinite
        ? rawReset.toInt()
        : null;
    final rawSlot = raw['colorSlot'];
    final colorSlot = rawSlot is num && rawSlot.isFinite ? rawSlot.toInt() : 0;
    return CachedQuotaWindow(
      label: label.trim(),
      remainingPercent: pct.toDouble().clamp(0.0, 100.0),
      resetAtMs: resetAtMs,
      colorSlot: colorSlot < 0 ? 0 : colorSlot,
    );
  }
}

/// 单个 ZCode 账号最近一次实时拉取的 GLM Coding Plan 摘要缓存。
class CachedOfficialQuota {
  const CachedOfficialQuota({
    required this.accountId,
    required this.cachedAtMs,
    required this.family,
    required this.planName,
    required this.windows,
    this.todayTotalTokens,
    this.todayPeakTokens,
  });

  final String accountId;
  final int cachedAtMs;
  final String family;
  final String planName;
  final List<CachedQuotaWindow> windows;
  final num? todayTotalTokens;
  final num? todayPeakTokens;

  DateTime get cachedAt => DateTime.fromMillisecondsSinceEpoch(cachedAtMs);

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'cachedAtMs': cachedAtMs,
    'family': family == 'zai' ? 'zai' : 'bigmodel',
    'planName': planName,
    'windows': [for (final w in windows.take(6)) w.toJson()],
    if (todayTotalTokens != null) 'todayTotalTokens': todayTotalTokens,
    if (todayPeakTokens != null) 'todayPeakTokens': todayPeakTokens,
  };

  static CachedOfficialQuota? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final accId = raw['accountId'];
    final cachedAtMs = raw['cachedAtMs'];
    final planName = raw['planName'];
    final rawWindows = raw['windows'];
    if (accId is! String || accId.trim().isEmpty) return null;
    if (cachedAtMs is! num || !cachedAtMs.isFinite || cachedAtMs < 0) {
      return null;
    }
    if (planName is! String || planName.trim().isEmpty) return null;
    if (rawWindows is! List) return null;
    final windows = <CachedQuotaWindow>[];
    for (final w in rawWindows) {
      if (windows.length >= 6) break;
      final parsed = CachedQuotaWindow.fromJson(w);
      if (parsed != null) windows.add(parsed);
    }
    if (windows.isEmpty) return null;
    final rawFam = raw['family'];
    final family = rawFam == 'zai' ? 'zai' : 'bigmodel';
    final rawTotal = raw['todayTotalTokens'];
    final rawPeak = raw['todayPeakTokens'];
    return CachedOfficialQuota(
      accountId: accId.trim(),
      cachedAtMs: cachedAtMs.toInt(),
      family: family,
      planName: planName.trim(),
      windows: List.unmodifiable(windows),
      todayTotalTokens: rawTotal is num && rawTotal.isFinite ? rawTotal : null,
      todayPeakTokens: rawPeak is num && rawPeak.isFinite ? rawPeak : null,
    );
  }
}

/// 格式化缓存时间标签（已处理中英文两段预译，避免 EN 出现混合中文）。
String formatOfficialQuotaCacheAge(DateTime cachedAt, [DateTime? now]) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(cachedAt);
  final String age;
  if (diff.inSeconds < 60) {
    age = tr('刚刚');
  } else if (diff.inMinutes < 60) {
    age = tr('${diff.inMinutes} 分钟前');
  } else if (diff.inHours < 24) {
    age = tr('${diff.inHours} 小时前');
  } else {
    final days = diff.inDays;
    age = tr('$days 天前');
  }
  return '${tr('缓存于 ')}$age';
}

/// 解析官方 Start Plan 响应中的各额度桶（同时兼容桌面端 `getEntitlementSnapshot`
/// 与本机直连 `OfficialStartPlanDirectClient` 返回的规范结构）。
///
/// 关键口径（对照 `bigmodelUsageQuotaProvider.ts:1370,1451`）：
/// - Coding Plan 的 `quota.limits[].percentage` 是 0..100 的**已用**百分比；
/// - Start Plan 的 `quota.limits[].percentage` 与 `remaining.percentage` 在桌面 4.0
///   中为 `remaining / total` 的 0..1 **剩余**比例（旧版 mock/快照也可能为 0..100 已用）。
List<({String label, double remainingPercent, String resetText})>
extractStartPlanWindows(Map<String, dynamic>? ent) {
  if (ent == null) return const [];
  final quota = ent['quota'] is Map
      ? (ent['quota'] as Map).cast<String, dynamic>()
      : null;
  final limits = quota?['limits'] is List ? quota!['limits'] as List : null;
  final out = <({String label, double remainingPercent, String resetText})>[];

  final quotaLevel = '${quota?['level'] ?? ''}'.trim().toLowerCase();
  final isStartLevel =
      quotaLevel == 'start' ||
      quotaLevel == 'start-plan' ||
      quotaLevel == 'start plan';

  if (limits != null) {
    for (final raw in limits) {
      if (raw is! Map) continue;
      final limit = raw.cast<String, dynamic>();
      final type = '${limit['type'] ?? ''}'.trim();
      // Coding Plan 标准限额留给 Coding Plan 分支处理。
      if (type == 'TOKENS_LIMIT' ||
          type == 'CREDIT_LIMIT' ||
          type == 'TIME_LIMIT') {
        continue;
      }

      final isExplicitStartBucket =
          isStartLevel ||
          type == 'START_PLAN_BUCKET' ||
          limit.containsKey('remaining') ||
          limit.containsKey('bucketId') ||
          limit.containsKey('planId');

      // 1) 优先取显式 remainingPercent（直连解析产物）或 remaining / number 计算值
      double? pct;
      final explicitPct = limit['remainingPercent'];
      if (explicitPct is num && explicitPct.isFinite) {
        pct = explicitPct.toDouble().clamp(0.0, 100.0);
      } else {
        final total = _parseNum(limit['number']) ?? _parseNum(limit['unit']);
        final rem = _parseNum(limit['remaining']);
        if (total != null && total > 0 && rem != null) {
          pct = (rem / total * 100.0).clamp(0.0, 100.0);
        } else {
          final rawPct = _parseNum(limit['percentage']);
          if (rawPct != null) {
            // 仅显式 Start Plan 桶按 0..1 剩余比例解析，避免误把旧版 0%/1% 已用当剩余。
            pct = (isExplicitStartBucket && rawPct >= 0 && rawPct <= 1.0)
                ? (rawPct * 100.0).clamp(0.0, 100.0)
                : (100.0 - rawPct).clamp(0.0, 100.0);
          }
        }
      }
      if (pct == null) continue;

      // 2) 优先使用服务端面向用户的 show_name（usageDetails[0].displayName / label）
      String label = '';
      final directLabel = limit['label'];
      if (directLabel is String && directLabel.trim().isNotEmpty) {
        label = directLabel.trim();
      }
      if (label.isEmpty && limit['usageDetails'] is List) {
        for (final d in (limit['usageDetails'] as List)) {
          if (d is! Map) continue;
          final dn = d['displayName'];
          if (dn is String && dn.trim().isNotEmpty) {
            label = dn.trim();
            break;
          }
          final mc = d['modelCode'];
          if (mc is String && mc.trim().isNotEmpty) {
            label = mc.trim();
            break;
          }
        }
      }
      if (label.isEmpty) label = '剩余额度';

      out.add((
        label: label,
        remainingPercent: pct,
        resetText: formatResetTime(limit['nextResetTime']),
      ));
    }
  }

  if (out.isNotEmpty) return out;

  final remainingObj = ent['remaining'] is Map
      ? (ent['remaining'] as Map).cast<String, dynamic>()
      : null;
  if (remainingObj != null && remainingObj['isShow'] == true) {
    double pct;
    final total = _parseNum(remainingObj['total']);
    final count = _parseNum(remainingObj['count']);
    final rawPct = _parseNum(remainingObj['percentage']);
    if (total != null && total > 0 && count != null) {
      pct = (count / total * 100.0).clamp(0.0, 100.0);
    } else if (rawPct != null &&
        rawPct >= 0 &&
        rawPct <= 1.0 &&
        remainingObj.containsKey('count')) {
      // 桌面 4.0 `buildZaiStartPlanRemaining` 返回 `{count, isShow, percentage: rem/total}`
      pct = (rawPct * 100.0).clamp(0.0, 100.0);
    } else {
      pct = quotaRemainingPercent(remainingObj);
    }
    out.add((
      label: '剩余额度',
      remainingPercent: pct,
      resetText: formatResetTime(remainingObj['nextResetTime']),
    ));
  }
  return out;
}

/// 从 `zcode-plan/billing/balance` 响应体解析为与桌面 `getEntitlementSnapshot`
/// 同构的 Start Plan 快照（纯函数，供单测直接覆盖）。
Map<String, dynamic> parseStartPlanBalanceEnvelope(
  String rawBody, {
  DateTime? now,
}) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(rawBody);
  } catch (_) {
    throw const FormatException('invalid start-plan balance json');
  }
  if (decoded is! Map) {
    throw const FormatException('start-plan balance payload is not a map');
  }
  final map = decoded.cast<String, dynamic>();
  final code = _parseNum(map['code'])?.toInt();
  if (code != null && code != 0) {
    return {
      'generatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'authenticated': true,
      'unavailableReason': 'unavailable',
      'quota': null,
      'remaining': null,
      '_directSource': true,
    };
  }
  final data = map['data'] is Map
      ? (map['data'] as Map).cast<String, dynamic>()
      : null;
  final rawPlans = data?['plans'] is List ? data!['plans'] as List : const [];
  final rawBalances = data?['balances'] is List
      ? data!['balances'] as List
      : const [];
  final rawServerTime = _parseNum(data?['server_time']);
  final refSec = rawServerTime != null && rawServerTime > 0
      ? (rawServerTime > 1e11 ? rawServerTime / 1000.0 : rawServerTime)
      : ((now ?? DateTime.now()).millisecondsSinceEpoch / 1000.0);

  final allPlans =
      <({String userPlanId, String planId, bool active, Map<String, dynamic> map})>[];
  final activePlans = <Map<String, dynamic>>[];
  Map<String, dynamic>? primaryStartPlan;
  for (final p in rawPlans) {
    if (p is! Map) continue;
    final pm = p.cast<String, dynamic>();
    final status = '${pm['status'] ?? ''}'.trim().toLowerCase();
    // 对齐桌面端 normalizeStartPlanExpiry：ends_at 已过期的套餐即使 status 仍为 active 也不再视为有效。
    var isExpired = status == 'expired';
    final rawEndsAt = _parseNum(pm['ends_at']);
    if (!isExpired && status == 'active' && rawEndsAt != null && rawEndsAt > 0) {
      final endsAtSec = rawEndsAt > 1e11 ? rawEndsAt / 1000.0 : rawEndsAt;
      if (endsAtSec <= refSec) isExpired = true;
    }
    final isActive = status == 'active' && !isExpired;
    final userPlanId = '${pm['user_plan_id'] ?? ''}'.trim();
    final rawPlanId = '${pm['plan_id'] ?? ''}'.trim();
    allPlans.add((
      userPlanId: userPlanId,
      planId: rawPlanId,
      active: isActive,
      map: pm,
    ));
    if (!isActive) continue;
    activePlans.add(pm);
    final planId = rawPlanId.toLowerCase();
    final name = '${pm['name'] ?? ''}'.trim().toLowerCase();
    if (primaryStartPlan == null &&
        (_isStartPlanIdentity(planId) || _isStartPlanIdentity(name))) {
      primaryStartPlan = pm;
    }
  }

  // 与桌面端 pickCurrentZaiStartPlan 对齐；同时若存在 active plan 且有 balances，
  // 兜底匹配首条带 balances 的 active plan（兼容活动期新福利包命名）。
  primaryStartPlan ??= activePlans.isNotEmpty && rawBalances.isNotEmpty
      ? activePlans.first
      : null;

  if (primaryStartPlan == null) {
    return {
      'generatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'authenticated': true,
      'unavailableReason': 'no_plan',
      'quota': null,
      'remaining': null,
      '_directSource': true,
    };
  }

  final limits = <Map<String, dynamic>>[];
  double sumTotal = 0;
  double sumRemaining = 0;
  int? earliestResetMs;

  for (final raw in rawBalances) {
    if (raw is! Map) continue;
    final b = raw.cast<String, dynamic>();
    // 对照桌面端 zaiStartPlanBilling.ts:178-186：优先按 user_plan_id 精确匹配归属套餐实例
    // （无 user_plan_id 再回退 plan_id），防同商品新旧两实例把过期实例余额混算进有效额度。
    final bUserPlanId = '${b['user_plan_id'] ?? ''}'.trim();
    final bPlanId = '${b['plan_id'] ?? ''}'.trim();
    if (allPlans.isNotEmpty) {
      final owners = allPlans.where((p) {
        if (bUserPlanId.isNotEmpty && p.userPlanId.isNotEmpty) {
          return p.userPlanId == bUserPlanId;
        }
        return bPlanId.isNotEmpty && p.planId == bPlanId;
      }).toList();
      if (owners.isNotEmpty && !owners.any((p) => p.active)) {
        continue;
      }
    }
    // 过滤桶级已过期的独立余额（expires_at <= refSec）。
    final expiresSec = _parseNum(b['expires_at']);
    final expiresNormSec = (expiresSec != null && expiresSec > 0)
        ? (expiresSec > 1e11 ? expiresSec / 1000.0 : expiresSec)
        : null;
    if (expiresNormSec != null && expiresNormSec <= refSec) {
      continue;
    }
    final total = _parseNum(b['total_units']);
    final used = _parseNum(b['used_units']);
    // 对照桌面注释：必须用 remaining_units，不得用 available_units 兜底。
    final remaining = _parseNum(b['remaining_units']);
    if (total == null && used == null && remaining == null) continue;
    final t = total ?? 0;
    final r = remaining ?? (total != null && used != null ? total - used : 0);
    if (t > 0) {
      sumTotal += t;
      sumRemaining += r.clamp(0, t);
    }

    final resetMs = expiresNormSec != null
        ? (expiresNormSec * 1000).toInt()
        : null;
    if (resetMs != null &&
        (earliestResetMs == null || resetMs < earliestResetMs)) {
      earliestResetMs = resetMs;
    }

    final showName = '${b['show_name'] ?? ''}'.trim();
    String capLabel = '';
    if (b['capabilities'] is List) {
      final caps = <String>[];
      for (final c in b['capabilities'] as List) {
        if (c is! String) continue;
        final s = c.startsWith('model:') ? c.substring('model:'.length) : c;
        if (s.trim().isNotEmpty) caps.add(s.trim());
      }
      capLabel = caps.join(', ');
    }
    final bucketLabel = showName.isNotEmpty
        ? showName
        : (capLabel.isNotEmpty ? capLabel : '剩余额度');

    final remainingPct = t > 0
        ? (r / t * 100.0).clamp(0.0, 100.0)
        : 0.0;
    limits.add({
      'type': 'START_PLAN_BUCKET',
      'label': bucketLabel,
      if (bPlanId.isNotEmpty) 'planId': bPlanId,
      'number': total,
      'usage': used,
      'currentValue': used,
      'remaining': remaining,
      'remainingPercent': remainingPct,
      'percentage': t > 0 ? (r / t).clamp(0.0, 1.0) : 0.0,
      'nextResetTime': resetMs,
      'usageDetails': [
        {
          if (showName.isNotEmpty) 'displayName': showName,
          if (capLabel.isNotEmpty) 'modelCode': capLabel,
          'usage': used ?? 0,
        },
      ],
    });
  }

  if (limits.isEmpty) {
    return {
      'generatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
      'authenticated': true,
      'unavailableReason': 'no_plan',
      'quota': null,
      'remaining': null,
      '_directSource': true,
    };
  }

  final planName = '${primaryStartPlan['name'] ?? ''}'.trim();
  return {
    'generatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch,
    'authenticated': true,
    'quota': {'level': 'Start', 'limits': limits},
    'subscription': {
      'details': [
        {'productName': planName.isNotEmpty ? planName : 'Start Plan'},
      ],
    },
    'remaining': {
      'isShow': true,
      'count': sumRemaining,
      'total': sumTotal,
      'percentage': sumTotal > 0 ? (sumRemaining / sumTotal).clamp(0.0, 1.0) : 0,
      'nextResetTime': earliestResetMs,
    },
    '_directSource': true,
  };
}

bool _isStartPlanIdentity(String value) =>
    value.contains('start-plan') ||
    value.contains('start plan') ||
    value.contains('start_plan') ||
    value.contains('startplan');

double? _parseNum(Object? raw) {
  if (raw is num) return raw.isFinite ? raw.toDouble() : null;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = double.tryParse(trimmed);
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }
  return null;
}

/// 手机直连官方 Start Plan 余额客户端（仅使用账号本地已存 `zcodejwttoken`）。
class OfficialStartPlanDirectClient {
  OfficialStartPlanDirectClient({
    ExternalQuotaHttpGet? httpGet,
    DateTime Function()? now,
    this.cacheTtl = const Duration(seconds: 20),
  }) : _httpGet = httpGet ?? _defaultHttpGet,
       _now = now ?? DateTime.now;

  final ExternalQuotaHttpGet _httpGet;
  final DateTime Function() _now;
  final Duration cacheTtl;

  static const int _maxResponseBytes = 256 * 1024;
  static const Duration _timeout = Duration(seconds: 10);

  final Map<String, ({String sig, DateTime at, Map<String, dynamic> snap})>
  _cache = {};
  final Map<String, int> _entryGen = {};

  void clearCache([String? accountId]) {
    if (accountId == null) {
      _cache.clear();
      _entryGen.updateAll((_, v) => v + 1);
    } else {
      _cache.remove(accountId);
      _entryGen[accountId] = (_entryGen[accountId] ?? 0) + 1;
    }
  }

  /// 查询指定账号的 Start Plan 快照（绝不泄露 JWT）。
  Future<Map<String, dynamic>> fetch({
    required String accountId,
    required String jwt,
    bool force = false,
  }) async {
    final cleanJwt = jwt.trim();
    final now = _now();
    if (!isValidExternalApiKey(cleanJwt)) {
      return {
        'generatedAt': now.millisecondsSinceEpoch,
        'authenticated': false,
        'unavailableReason': 'not_authenticated',
        'quota': null,
        'remaining': null,
        '_directSource': true,
      };
    }

    final sig = _hashJwt(cleanJwt);
    if (!force) {
      final hit = _cache[accountId];
      if (hit != null &&
          hit.sig == sig &&
          now.difference(hit.at) < cacheTtl) {
        return hit.snap;
      }
    }

    final gen = (_entryGen[accountId] ?? 0) + 1;
    _entryGen[accountId] = gen;

    try {
      final resp = await _httpGet(kOfficialStartPlanBalanceUri, {
        'Authorization': 'Bearer $cleanJwt',
        'Accept': 'application/json',
        'User-Agent': 'ZCodePocket/1.0',
      });
      final finished = _now();
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        if (_entryGen[accountId] == gen) _cache.remove(accountId);
        return {
          'generatedAt': finished.millisecondsSinceEpoch,
          'authenticated': false,
          'unavailableReason': 'not_authenticated',
          'quota': null,
          'remaining': null,
          '_directSource': true,
        };
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        if (_entryGen[accountId] == gen) _cache.remove(accountId);
        return {
          'generatedAt': finished.millisecondsSinceEpoch,
          'authenticated': true,
          'unavailableReason': 'unavailable',
          'quota': null,
          'remaining': null,
          '_directSource': true,
        };
      }
      final parsed = parseStartPlanBalanceEnvelope(resp.body, now: finished);
      if (_entryGen[accountId] == gen) {
        _cache[accountId] = (sig: sig, at: finished, snap: parsed);
      }
      return parsed;
    } catch (_) {
      if (_entryGen[accountId] == gen) _cache.remove(accountId);
      return {
        'generatedAt': _now().millisecondsSinceEpoch,
        'authenticated': true,
        'unavailableReason': 'unavailable',
        'quota': null,
        'remaining': null,
        '_directSource': true,
      };
    }
  }

  static String _hashJwt(String jwt) {
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    for (var i = 0; i < jwt.length; i++) {
      final c = jwt.codeUnitAt(i);
      h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 + c * 31) ^ (h1 >> 3)) & 0xFFFFFFFF;
    }
    return '${jwt.length}:${h1.toRadixString(16)}:${h2.toRadixString(16)}';
  }

  static Future<({int statusCode, String body})> _defaultHttpGet(
    Uri uri,
    Map<String, String> headers,
  ) async {
    if (uri.scheme != 'https' || uri.host != 'zcode.z.ai') {
      throw const FormatException('invalid official start-plan uri');
    }
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      return await () async {
        final req = await client.getUrl(uri);
        req.followRedirects = false;
        headers.forEach(req.headers.set);
        final res = await req.close();
        final chunks = <int>[];
        await for (final chunk in res) {
          if (chunks.length + chunk.length > _maxResponseBytes) {
            throw const FormatException('response body too large');
          }
          chunks.addAll(chunk);
        }
        return (
          statusCode: res.statusCode,
          body: utf8.decode(chunks, allowMalformed: true),
        );
      }().timeout(_timeout);
    } finally {
      client.close(force: true);
    }
  }
}

/// 进程级共享官方 Start Plan 直连客户端（供用量速览与账号清理链路共用，避免跨层循环依赖）。
final OfficialStartPlanDirectClient sharedStartPlanDirectClient =
    OfficialStartPlanDirectClient();
