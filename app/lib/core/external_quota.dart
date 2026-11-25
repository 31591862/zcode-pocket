/// 可扩展的外部订阅额度查询引擎（手机直连 HTTPS，凭用户自填 API Key
/// 实时查询，不依赖桌面在线、不走中继）。
///
/// 架构：
/// - 统一适配器接口 [ExternalQuotaAdapter] + 统一渲染模型
///   [ExternalQuotaSnapshot] / [ExternalQuotaWindow]；
/// - 内置适配器：[KimiCodingQuotaAdapter]、[OpenCodeGoQuotaAdapter]、
///   [ZhipuCodingQuotaAdapter]、[MimoTokenPlanQuotaAdapter]、
///   [OllamaCloudQuotaAdapter]、[CommandCodeQuotaAdapter]；后续接入其他
///   支持 API Key 查额度的平台只需新增适配器并加入
///   [kExternalQuotaAdapters]，UI 与加密存储层零改动。查询方式与开源工具
///   cc-switch 的实现同类（直连各家官方额度接口、仅读取额度）。
/// - 安全红线：仅允许干净的 HTTPS 端点（拒绝 HTTP、userinfo、query、
///   fragment）；禁用自动重定向防 Authorization 泄到明文；响应上限 256KB；
///   超时强关 HttpClient 防 socket 泄露；错误信息绝不回显 API Key。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'usage_format.dart' show findQuotaLimit;

/// 单个时间窗/配额条（例如 5 小时窗口、7 天额度、每周额度）。
class ExternalQuotaWindow {
  const ExternalQuotaWindow({
    required this.label,
    required this.usedPercent,
    required this.remainingPercent,
    this.resetAt,
    this.resetLabel = '',
  });

  final String label;
  final double usedPercent;
  final double remainingPercent;
  final DateTime? resetAt;
  final String resetLabel;
}

/// 单个外部订阅账号的查询结果（成功或降级错误）。
class ExternalQuotaSnapshot {
  const ExternalQuotaSnapshot({
    String? entryId,
    required this.providerId,
    required this.providerName,
    this.accountLabel = '',
    required this.ok,
    required this.fetchedAt,
    this.windows = const [],
    this.notes = const [],
    this.error,
    this.hint,
  }) : entryId = (entryId != null && entryId != '') ? entryId : providerId;

  final String entryId;
  final String providerId;
  final String providerName;
  final String accountLabel;
  final bool ok;
  final DateTime fetchedAt;
  final List<ExternalQuotaWindow> windows;
  final List<String> notes;
  final String? error;
  final String? hint;

  /// 展示标题：无备注名时为平台名（如 Kimi Coding），多账号填写备注后为
  /// `Kimi Coding · 主号`。
  String get displayTitle {
    final trimmed = accountLabel.trim();
    return trimmed.isEmpty ? providerName : '$providerName · $trimmed';
  }

  ExternalQuotaSnapshot withAccount({
    required String entryId,
    required String accountLabel,
  }) => ExternalQuotaSnapshot(
    entryId: entryId,
    providerId: providerId,
    providerName: providerName,
    accountLabel: accountLabel,
    ok: ok,
    fetchedAt: fetchedAt,
    windows: windows,
    notes: notes,
    error: error,
    hint: hint,
  );
}

/// 外部订阅账号最大条目数上限（UI 与存储层共同守卫）。
const int kMaxExternalQuotaEntries = 20;

/// 速览卡片规范 ID：官方 GLM Coding Plan / GLM Start Plan / 外部账号前缀。
const String kUsageCardOfficialCoding = 'official:coding';
const String kUsageCardOfficialStart = 'official:start';
const String kUsageCardOfficialCodingPrefix = 'official:coding:';
const String kUsageCardOfficialStartPrefix = 'official:start:';
const String kUsageCardExternalPrefix = 'ext:';

String usageCardOfficialCodingId(String accountId) =>
    '$kUsageCardOfficialCodingPrefix$accountId';

String usageCardOfficialStartId(String accountId) =>
    '$kUsageCardOfficialStartPrefix$accountId';

String usageCardExternalId(String entryId) =>
    '$kUsageCardExternalPrefix$entryId';

/// 外部订阅额度查询实现源码公开地址（用于「安全说明 · 开源可审」核对）。
const String kExternalQuotaSourceUrl =
    'https://github.com/JZYLukis/zcode-pocket/blob/main/app/lib/core/external_quota.dart';

/// 「用量速览」自定义展示偏好：卡片顺序、显示开关与官方来源选择。
/// - 默认规则：显示 GLM Coding Plan + 有福利包时自动显示 GLM Start Plan；
/// - 外部账号未配置时不占位，配置后可自由拖动排序或临时隐藏而不删 Key；
/// - 非 GLM 用户可直接关闭官方卡片，跳过官方 RPC。
class UsageQuickLayoutPrefs {
  const UsageQuickLayoutPrefs({
    this.order = const [kUsageCardOfficialCoding, kUsageCardOfficialStart],
    this.hidden = const <String>{},
    this.codingScope = 'auto',
    this.startScope = 'auto',
  });

  static const defaults = UsageQuickLayoutPrefs();
  static const _validScopes = {'auto', 'bigmodel', 'zai'};
  static const _maxStoredIds = 60;

  /// 自定义展示顺序（值为规范 cardId）。
  final List<String> order;

  /// 用户手动隐藏的卡片集合（值为规范 cardId）。
  final Set<String> hidden;

  /// GLM Coding Plan 来源：'auto' | 'bigmodel' | 'zai'。
  final String codingScope;

  /// GLM Start Plan 来源：'auto' | 'bigmodel' | 'zai'。
  final String startScope;

  bool isVisible(String cardId) => !hidden.contains(cardId);

  /// 判断官方卡片是否可见（兼容单账号↔多账号边界平滑承接）：
  /// - 1 → 多账号且尚未落盘过 per-account 偏好时，继承单账号 `official:coding`/`official:start` 的隐藏态；
  /// - 多账号删号退回单账号时，若传入 `singleAccountId` 且其 per-account 键处于隐藏态，同步继承隐藏。
  bool isOfficialCardVisible(
    String cardId, {
    required bool isMultiAccount,
    String? singleAccountId,
  }) {
    if (hidden.contains(cardId)) return false;
    final hasPerAccountPref =
        order.any(
          (id) =>
              id.startsWith(kUsageCardOfficialCodingPrefix) ||
              id.startsWith(kUsageCardOfficialStartPrefix),
        ) ||
        hidden.any(
          (id) =>
              id.startsWith(kUsageCardOfficialCodingPrefix) ||
              id.startsWith(kUsageCardOfficialStartPrefix),
        );
    if (isMultiAccount && !hasPerAccountPref) {
      if (cardId.startsWith(kUsageCardOfficialCodingPrefix) &&
          hidden.contains(kUsageCardOfficialCoding)) {
        return false;
      }
      if (cardId.startsWith(kUsageCardOfficialStartPrefix) &&
          hidden.contains(kUsageCardOfficialStart)) {
        return false;
      }
    }
    if (!isMultiAccount &&
        singleAccountId != null &&
        singleAccountId.trim().isNotEmpty) {
      final aid = singleAccountId.trim();
      if (cardId == kUsageCardOfficialCoding &&
          hidden.contains(usageCardOfficialCodingId(aid))) {
        return false;
      }
      if (cardId == kUsageCardOfficialStart &&
          hidden.contains(usageCardOfficialStartId(aid))) {
        return false;
      }
    }
    return true;
  }

  bool get isDefault =>
      hidden.isEmpty &&
      codingScope == 'auto' &&
      startScope == 'auto' &&
      order.length == 2 &&
      order[0] == kUsageCardOfficialCoding &&
      order[1] == kUsageCardOfficialStart;

  /// 按当前官方卡片与外部账号列表生成去重后的完整展示顺序。
  /// 单账号保持经典 `[official:coding, official:start]`；多账号时调用方传入
  /// 按账号派生的 `[official:coding:<id>, official:start:<id>, ...]`。
  List<String> resolvedOrder(
    List<ExternalQuotaProviderConfig> externalEntries, {
    List<String>? officialCardIds,
  }) {
    final officials = (officialCardIds != null && officialCardIds.isNotEmpty)
        ? officialCardIds
        : const [kUsageCardOfficialCoding, kUsageCardOfficialStart];
    final validOfficial = <String>{...officials};
    final validExternal = <String>{
      for (final e in externalEntries) usageCardExternalId(e.id),
    };
    final result = <String>[];
    final seen = <String>{};

    void addIfValid(String id) {
      if (seen.contains(id)) return;
      if (!validOfficial.contains(id) && !validExternal.contains(id)) return;
      seen.add(id);
      result.add(id);
    }

    for (final id in order) {
      addIfValid(id);
    }
    for (final id in officials) {
      addIfValid(id);
    }
    for (final e in externalEntries) {
      addIfValid(usageCardExternalId(e.id));
    }
    return result;
  }

  UsageQuickLayoutPrefs copyWith({
    List<String>? order,
    Set<String>? hidden,
    String? codingScope,
    String? startScope,
  }) => UsageQuickLayoutPrefs(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    codingScope: codingScope ?? this.codingScope,
    startScope: startScope ?? this.startScope,
  );

  Map<String, dynamic> toJson() => {
    'order': order.take(_maxStoredIds).toList(),
    'hidden': hidden.take(_maxStoredIds).toList(),
    'codingScope': _normalizeScope(codingScope),
    'startScope': _normalizeScope(startScope),
  };

  static String _normalizeScope(Object? raw) {
    if (raw is String && _validScopes.contains(raw)) return raw;
    return 'auto';
  }

  static UsageQuickLayoutPrefs fromJson(dynamic raw) {
    if (raw is! Map) return defaults;
    final parsedOrder = <String>[];
    final rawOrder = raw['order'];
    if (rawOrder is List) {
      final seen = <String>{};
      for (final item in rawOrder) {
        if (parsedOrder.length >= _maxStoredIds) break;
        if (item is! String) continue;
        final trimmed = item.trim();
        if (trimmed.isEmpty || !seen.add(trimmed)) continue;
        parsedOrder.add(trimmed);
      }
    }
    final parsedHidden = <String>{};
    final rawHidden = raw['hidden'];
    if (rawHidden is List) {
      for (final item in rawHidden) {
        if (parsedHidden.length >= _maxStoredIds) break;
        if (item is! String) continue;
        final trimmed = item.trim();
        if (trimmed.isNotEmpty) parsedHidden.add(trimmed);
      }
    }
    return UsageQuickLayoutPrefs(
      order: parsedOrder.isEmpty
          ? const [kUsageCardOfficialCoding, kUsageCardOfficialStart]
          : List.unmodifiable(parsedOrder),
      hidden: Set.unmodifiable(parsedHidden),
      codingScope: _normalizeScope(raw['codingScope']),
      startScope: _normalizeScope(raw['startScope']),
    );
  }
}

/// 校验 API Key 是否可安全写入 HTTP Authorization 头（拒绝内部换行、控制字符与非 ASCII）。
bool isValidExternalApiKey(String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) return false;
  for (var i = 0; i < trimmed.length; i++) {
    final unit = trimmed.codeUnitAt(i);
    if (unit < 0x20 || unit > 0x7E) return false;
  }
  return true;
}

/// 单个外部订阅账号的本地配置（存于 UiPrefs 硬件加密存储；同一 providerId
/// 允许存在多条配置，靠 [id] 区分、靠 [label] 标注主号/备用等别名）。
class ExternalQuotaProviderConfig {
  const ExternalQuotaProviderConfig({
    String? id,
    required this.providerId,
    required this.apiKey,
    this.baseUrl = '',
    this.label = '',
  }) : id = (id != null && id != '') ? id : providerId;

  final String id;
  final String providerId;
  final String apiKey;
  final String baseUrl;
  final String label;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'providerId': providerId,
    'apiKey': apiKey,
    if (label.trim().isNotEmpty) 'label': label.trim(),
    if (baseUrl.trim().isNotEmpty) 'baseUrl': baseUrl.trim(),
  };

  static ExternalQuotaProviderConfig? fromJson(
    String fallbackId,
    dynamic raw,
  ) {
    if (raw is! Map) return null;
    final rawKey = raw['apiKey'];
    if (rawKey is! String) return null;
    final key = rawKey.trim();
    if (key.isEmpty) return null;

    final rawPid = raw['providerId'];
    final String pid;
    if (rawPid == null) {
      pid = fallbackId.trim();
    } else if (rawPid is String) {
      pid = rawPid.trim();
    } else {
      return null;
    }
    if (pid.isEmpty) return null;

    final rawIdField = raw['id'];
    final String id;
    if (rawIdField is String && rawIdField.trim().isNotEmpty) {
      id = rawIdField.trim();
    } else {
      final fb = fallbackId.trim();
      id = fb.isNotEmpty ? fb : pid;
    }

    final rawBase = raw['baseUrl'];
    final base = rawBase is String ? rawBase.trim() : '';
    final rawLabel = raw['label'];
    final label = rawLabel is String ? rawLabel.trim() : '';
    return ExternalQuotaProviderConfig(
      id: id,
      providerId: pid,
      apiKey: key,
      baseUrl: base,
      label: label,
    );
  }
}

/// 外部额度查询适配器接口。
abstract class ExternalQuotaAdapter {
  const ExternalQuotaAdapter();

  String get id;
  String get displayName;
  String get defaultBaseUrl;
  String get endpointPath;
  String get authHint;

  /// 鉴权头形态：true=`Authorization: Bearer <key>`（标准）；false=直接放
  /// key（智谱开放平台额度接口不加 Bearer 前缀）。
  bool get useBearerAuth => true;

  /// 随请求附带的其他请求头（多数平台不需要）。
  Map<String, String> get extraHeaders => const {};

  /// 解析提供方 JSON 响应为统一 [ExternalQuotaSnapshot]；结构不符时抛
  /// [FormatException]，供应商在成功响应里回报的鉴权失败抛
  /// [ExternalQuotaAuthException]。
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now);
}

/// 供应商在 HTTP 200 里回报的鉴权失败（如智谱额度接口返回
/// `{success:false, code:401}`）——与 HTTP 401 同样按「Key 失效」呈现，
/// 而不是落进「返回数据格式无法识别」。
class ExternalQuotaAuthException implements Exception {
  const ExternalQuotaAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 校验并拼接最终 HTTPS 请求地址：
/// - 仅允许 `https://` 且 host 非空；
/// - 拒绝 userinfo（防 `https://good@evil` 主机伪装）、query、fragment；
/// - 通过 Uri.replace 拼接路径段，避免字符串拼接畸变。
Uri? resolveExternalQuotaUri(
  ExternalQuotaAdapter adapter, {
  String customBaseUrl = '',
}) {
  final rawBase = customBaseUrl.trim().isEmpty
      ? adapter.defaultBaseUrl
      : customBaseUrl.trim();
  final baseUri = Uri.tryParse(rawBase);
  if (baseUri == null ||
      baseUri.scheme != 'https' ||
      baseUri.host.isEmpty ||
      baseUri.userInfo.isNotEmpty ||
      baseUri.hasQuery ||
      baseUri.hasFragment) {
    return null;
  }
  final cleanBasePath = baseUri.path.replaceFirst(RegExp(r'/+$'), '');
  final cleanEndpoint = adapter.endpointPath.startsWith('/')
      ? adapter.endpointPath
      : '/${adapter.endpointPath}';
  return baseUri.replace(path: '$cleanBasePath$cleanEndpoint');
}

DateTime? _parseIsoTime(Object? raw) {
  if (raw == null) return null;
  final s = '$raw'.trim();
  if (s.isEmpty) return null;
  final parsed = DateTime.tryParse(s);
  return parsed?.toLocal();
}

/// 秒级时间戳（兼容毫秒级）→ 本地时间；非有限数值返回 null。
DateTime? _parseEpochTime(Object? raw) {
  if (raw is! num || !raw.isFinite) return null;
  final v = raw.toInt();
  return v < 100000000000
      ? DateTime.fromMillisecondsSinceEpoch(v * 1000)
      : DateTime.fromMillisecondsSinceEpoch(v);
}

/// 「YYYY-MM-DD HH:mm:ss」形态的 UTC 时间（无 T、无时区后缀——小米
/// Token Plan 的周期时间口径）→ 本地时间；标准 ISO 形态照常解析。
/// 注意：Dart 的 DateTime.parse 把空格分隔且无时区的写法当作**本地**时间，
/// 所以必须先认出这种紧凑 UTC 形态再补 Z，不能直接交给 tryParse。
DateTime? _parseUtcCompactTime(Object? raw) {
  if (raw == null) return null;
  final s = '$raw'.trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(s)) {
    return DateTime.tryParse('${s.replaceFirst(' ', 'T')}Z')?.toLocal();
  }
  return DateTime.tryParse(s)?.toLocal();
}

String formatExternalResetTime(DateTime? resetAt, DateTime now) {
  if (resetAt == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  final localNow = now.toLocal();
  final sameDay =
      resetAt.year == localNow.year &&
      resetAt.month == localNow.month &&
      resetAt.day == localNow.day;
  final hm = '${two(resetAt.hour)}:${two(resetAt.minute)}';
  return sameDay ? hm : '${two(resetAt.month)}-${two(resetAt.day)} $hm';
}

/// 严格解析有限非负数值（null/非数字/NaN/Infinity/负数返回 null，不静默当 0）。
double? _parseStrictNonNegative(Object? raw) {
  if (raw == null) return null;
  final double? val;
  if (raw is num) {
    val = raw.toDouble();
  } else if (raw is String) {
    val = double.tryParse(raw.trim());
  } else {
    return null;
  }
  if (val == null || !val.isFinite || val < 0) return null;
  return val;
}

ExternalQuotaWindow? _tryMakeWindow(
  String label,
  Object? rawUsedPercent,
  Object? rawReset,
  DateTime now,
) => _makeWindow(
  label,
  _parseStrictNonNegative(rawUsedPercent),
  _parseIsoTime(rawReset),
  now,
);

/// 已用百分比（任意有限数值，内部钳到 0~100）+ 重置时间 → 窗口。
ExternalQuotaWindow? _makeWindow(
  String label,
  double? usedPercent,
  DateTime? resetAt,
  DateTime now,
) {
  if (usedPercent == null || !usedPercent.isFinite) return null;
  final used = usedPercent.clamp(0.0, 100.0);
  final remaining = (100.0 - used).clamp(0.0, 100.0);
  return ExternalQuotaWindow(
    label: label,
    usedPercent: double.parse(used.toStringAsFixed(1)),
    remainingPercent: double.parse(remaining.toStringAsFixed(1)),
    resetAt: resetAt,
    resetLabel: formatExternalResetTime(resetAt, now),
  );
}

/// Kimi Coding 订阅额度适配器（GET https://api.kimi.com/coding/v1/usages）。
class KimiCodingQuotaAdapter extends ExternalQuotaAdapter {
  const KimiCodingQuotaAdapter();

  @override
  String get id => 'kimi_coding';

  @override
  String get displayName => 'Kimi Coding';

  @override
  String get defaultBaseUrl => 'https://api.kimi.com/coding';

  @override
  String get endpointPath => '/v1/usages';

  @override
  String get authHint => '请确认使用的是 Kimi Coding API Key（kimi.com/code/console）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    final usages = data['usages'];
    final windows = <ExternalQuotaWindow>[];
    if (usages is Map) {
      for (final pair in const [
        ('limit_5h', '5 小时窗口'),
        ('limit_7d', '7 天额度'),
      ]) {
        final item = usages[pair.$1];
        if (item is Map) {
          final ratio = _parseStrictNonNegative(item['used_ratio']);
          if (ratio == null) continue;
          final w = _tryMakeWindow(
            pair.$2,
            ratio.clamp(0.0, 1.0) * 100.0,
            item['reset_time'],
            now,
          );
          if (w != null) windows.add(w);
        }
      }
    }
    if (windows.isEmpty) {
      throw const FormatException('missing valid usages');
    }
    final notes = <String>[];
    final limits = data['limits'];
    if (limits is List && limits.isNotEmpty && limits.first is Map) {
      final detail = (limits.first as Map)['detail'];
      if (detail is Map) {
        final remNum = _parseStrictNonNegative(detail['remaining']);
        if (remNum != null) {
          String fmtNum(double v) => v == v.roundToDouble()
              ? '${v.round()}'
              : v.toStringAsFixed(1);
          final limNum = _parseStrictNonNegative(detail['limit']);
          final remStr = fmtNum(remNum);
          notes.add(
            limNum != null && limNum > 0
                ? '5 小时请求数 剩余 $remStr / ${fmtNum(limNum)}'
                : '5 小时请求数 剩余 $remStr',
          );
        }
      }
    }
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: windows,
      notes: notes,
    );
  }
}

/// OpenCode Go（OCG）订阅额度适配器（GET https://opencode.ai/zen/go/v1/usage）。
class OpenCodeGoQuotaAdapter extends ExternalQuotaAdapter {
  const OpenCodeGoQuotaAdapter();

  @override
  String get id => 'opencode_go';

  @override
  String get displayName => 'OpenCode Go';

  @override
  String get defaultBaseUrl => 'https://opencode.ai/zen/go/v1';

  @override
  String get endpointPath => '/usage';

  @override
  String get authHint => '请确认使用的是 OpenCode Go API Key（opencode.ai/auth）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    final usage = data['usage'];
    final windows = <ExternalQuotaWindow>[];
    if (usage is Map) {
      for (final pair in const [
        ('rolling', '5 小时滚动'),
        ('weekly', '每周额度'),
        ('monthly', '每月额度'),
      ]) {
        final item = usage[pair.$1];
        if (item is Map) {
          final w = _tryMakeWindow(
            pair.$2,
            item['percent'],
            item['resetsAt'],
            now,
          );
          if (w != null) windows.add(w);
        }
      }
    }
    if (windows.isEmpty) {
      throw const FormatException('missing valid usage');
    }
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: windows,
    );
  }
}

/// 智谱 GLM Coding Plan 额度适配器（GET
/// https://open.bigmodel.cn/api/monitor/usage/quota/limit）。与首页官方
/// 卡片读桌面快照不同，这里用用户自己的 Coding Plan API Key 手机直连，
/// 桌面离线也能查；国际版账号把接口地址改为 https://api.z.ai（同路径
/// 同结构）。响应里的 limits[] 与官方卡片同源：percentage=已用占比，
/// unit 3=5 小时窗口、6=每周，nextResetTime=毫秒时间戳。
class ZhipuCodingQuotaAdapter extends ExternalQuotaAdapter {
  const ZhipuCodingQuotaAdapter();

  @override
  String get id => 'zhipu_coding';

  @override
  String get displayName => 'GLM Coding Plan 直连';

  @override
  String get defaultBaseUrl => 'https://open.bigmodel.cn';

  @override
  String get endpointPath => '/api/monitor/usage/quota/limit';

  @override
  bool get useBearerAuth => false;

  @override
  Map<String, String> get extraHeaders => const {
    'Accept-Language': 'en-US,en',
  };

  @override
  String get authHint =>
      '请确认使用的是智谱 GLM Coding Plan API Key（国际版账号请把接口地址改为 https://api.z.ai）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    // 鉴权失败走 HTTP 200 + 业务码：{"code":401,"msg":"token expired or
    // incorrect","success":false}（实测形态）。
    if (data['success'] == false) {
      if (data['code'] == 401) {
        throw const ExternalQuotaAuthException('API Key 失效或未授权（401）');
      }
      throw const FormatException('zhipu business error');
    }
    final payload = data['data'];
    final rawLimits = payload is Map ? payload['limits'] : null;
    final windows = <ExternalQuotaWindow>[];
    if (rawLimits is List) {
      for (final pair in const [(3, '5 小时窗口'), (6, '每周额度')]) {
        final limit = findQuotaLimit(rawLimits, tokenKind: true, unit: pair.$1);
        if (limit == null) continue;
        final w = _makeWindow(
          pair.$2,
          _parseStrictNonNegative(limit['percentage']),
          _parseEpochTime(limit['nextResetTime']),
          now,
        );
        if (w != null) windows.add(w);
      }
    }
    if (windows.isEmpty) {
      throw const FormatException('missing valid limits');
    }
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: windows,
    );
  }
}

/// 小米 MiMo Token Plan 额度适配器（GET
/// https://token-plan-cn.xiaomimimo.com/v1/platform/token_plan）。只认
/// Token Plan 专用 Key（tp- 开头）——按量付费的 sk- Key 会被 401 拒绝。
/// 套餐有月付也有年付，周期长短不固定，所以只折成一档「本期额度」。
class MimoTokenPlanQuotaAdapter extends ExternalQuotaAdapter {
  const MimoTokenPlanQuotaAdapter();

  @override
  String get id => 'mimo_token_plan';

  @override
  String get displayName => '小米 MiMo Token Plan';

  @override
  String get defaultBaseUrl => 'https://token-plan-cn.xiaomimimo.com';

  @override
  String get endpointPath => '/v1/platform/token_plan';

  @override
  String get authHint =>
      '请确认使用的是小米 MiMo Token Plan API Key（tp- 开头；sk- 开头是按量付费 Key）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    final quota = data['quota'];
    final total = quota is Map
        ? _parseStrictNonNegative(quota['total_credits'])
        : null;
    if (total == null || total <= 0) {
      throw const FormatException('missing token plan credits');
    }
    final used = quota['used_credits'] == null
        ? null
        : _parseStrictNonNegative(quota['used_credits']);
    final remaining = quota['remaining_credits'] == null
        ? null
        : _parseStrictNonNegative(quota['remaining_credits']);
    final double? usedCredits = used ?? (remaining != null ? total - remaining : null);
    if (usedCredits == null) {
      throw const FormatException('missing token plan usage');
    }
    final period = data['period'];
    final window = _makeWindow(
      '本期额度',
      usedCredits / total * 100.0,
      period is Map ? _parseUtcCompactTime(period['end_at']) : null,
      now,
    );
    if (window == null) {
      throw const FormatException('missing token plan period');
    }
    String fmtNum(double v) => v == v.roundToDouble()
        ? '${v.round()}'
        : v.toStringAsFixed(1);
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: [window],
      notes: [
        '本期积分 剩余 ${fmtNum(remaining ?? (total - usedCredits))} / ${fmtNum(total)}',
      ],
    );
  }
}

/// Ollama Cloud 额度适配器（GET https://ollama.com/api/balance）。有月度
/// 美元额度（allowance/balance）时折成「每月额度」一档；否则取会话与周
/// 两个窗口的剩余百分比。
class OllamaCloudQuotaAdapter extends ExternalQuotaAdapter {
  const OllamaCloudQuotaAdapter();

  @override
  String get id => 'ollama_cloud';

  @override
  String get displayName => 'Ollama Cloud';

  @override
  String get defaultBaseUrl => 'https://ollama.com';

  @override
  String get endpointPath => '/api/balance';

  @override
  String get authHint =>
      '请确认使用的是 Ollama Cloud API Key（ollama.com/settings/keys）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    final included = data['included'];
    if (included is! Map) {
      throw const FormatException('missing included');
    }
    final windows = <ExternalQuotaWindow>[];
    final balance = _parseStrictNonNegative(included['balance_usd']);
    final allowance = _parseStrictNonNegative(included['allowance_usd']);
    if (balance != null && allowance != null && allowance > 0) {
      final period = included['period'];
      final w = _makeWindow(
        '每月额度',
        (allowance - balance) / allowance * 100.0,
        period is Map ? _parseIsoTime(period['until']) : null,
        now,
      );
      if (w != null) windows.add(w);
    }
    if (windows.isEmpty) {
      for (final pair in const [('session', '5 小时窗口'), ('weekly', '每周额度')]) {
        final win = included[pair.$1];
        if (win is! Map) continue;
        final remaining = _parseStrictNonNegative(win['remaining_percent']);
        if (remaining == null) continue;
        final w = _makeWindow(
          pair.$2,
          100.0 - remaining,
          _parseIsoTime(win['resets_at']),
          now,
        );
        if (w != null) windows.add(w);
      }
    }
    if (windows.isEmpty) {
      throw const FormatException('missing valid balance');
    }
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: windows,
    );
  }
}

/// Command Code 额度适配器（GET
/// https://api.commandcode.ai/alpha/billing/credits）。/alpha 是其官方
/// 命令行工具使用的私有路由，未公开文档化；这里只取 5 小时与周两个窗口
/// 的已用/上限。字段变动时按「返回数据格式无法识别」降级，不影响其他
/// 账号。
class CommandCodeQuotaAdapter extends ExternalQuotaAdapter {
  const CommandCodeQuotaAdapter();

  @override
  String get id => 'command_code';

  @override
  String get displayName => 'Command Code';

  @override
  String get defaultBaseUrl => 'https://api.commandcode.ai';

  @override
  String get endpointPath => '/alpha/billing/credits';

  @override
  String get authHint =>
      '请确认使用的是 Command Code API Key（该接口为官方命令行工具的私有路由，可能变动）';

  @override
  ExternalQuotaSnapshot parseResponse(Map<String, dynamic> data, DateTime now) {
    // windowLimits 在响应根层；兼容嵌在 credits 里的形态。
    final credits = data['credits'];
    final raw = data['windowLimits'] ?? (credits is Map ? credits['windowLimits'] : null);
    if (raw is! Map) {
      throw const FormatException('missing window limits');
    }
    final windows = <ExternalQuotaWindow>[];
    for (final pair in const [('fiveHour', '5 小时窗口'), ('weekly', '每周额度')]) {
      final win = raw[pair.$1];
      if (win is! Map) continue;
      final used = _parseStrictNonNegative(win['used']);
      final cap = _parseStrictNonNegative(win['cap']);
      if (used == null || cap == null || cap <= 0) continue;
      final w = _makeWindow(
        pair.$2,
        used / cap * 100.0,
        _parseIsoTime(win['resetAt']),
        now,
      );
      if (w != null) windows.add(w);
    }
    if (windows.isEmpty) {
      throw const FormatException('missing valid window limits');
    }
    return ExternalQuotaSnapshot(
      providerId: id,
      providerName: displayName,
      ok: true,
      fetchedAt: now,
      windows: windows,
    );
  }
}

/// 已注册的外部配额适配器清单（展示顺序即此列表顺序）。
const List<ExternalQuotaAdapter> kExternalQuotaAdapters = [
  KimiCodingQuotaAdapter(),
  OpenCodeGoQuotaAdapter(),
  ZhipuCodingQuotaAdapter(),
  MimoTokenPlanQuotaAdapter(),
  OllamaCloudQuotaAdapter(),
  CommandCodeQuotaAdapter(),
];

ExternalQuotaAdapter? externalQuotaAdapterById(String id) {
  for (final a in kExternalQuotaAdapters) {
    if (a.id == id) return a;
  }
  return null;
}

typedef ExternalQuotaHttpGet =
    Future<({int statusCode, String body})> Function(
      Uri uri,
      Map<String, String> headers,
    );

/// 外部订阅额度 HTTP 客户端（带短缓存 + 代际防乱序覆盖 + 256KB 上限 + 超时强关）。
class ExternalQuotaClient {
  ExternalQuotaClient({
    ExternalQuotaHttpGet? httpGet,
    DateTime Function()? now,
    this.cacheTtl = const Duration(seconds: 20),
    this.timeout = const Duration(seconds: 12),
    this.adapters = kExternalQuotaAdapters,
  }) : _httpGet = httpGet,
       _now = now ?? DateTime.now;

  static const _maxBodyBytes = 256 * 1024;
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36';

  final ExternalQuotaHttpGet? _httpGet;
  final DateTime Function() _now;
  final Duration cacheTtl;
  final Duration timeout;
  final List<ExternalQuotaAdapter> adapters;

  /// 内存短缓存（按 entryId 分桶）：存完整配置四元组 (providerId, baseUrl,
  /// apiKey, label) 消除碰撞，并以全局 _cacheEpoch + 单条 _entryGen 双代际防止
  /// 慢请求回写陈旧快照、覆盖强制刷新或复活已删除账号。
  final Map<
    String,
    ({
      String providerId,
      String baseUrl,
      String apiKey,
      String label,
      int epoch,
      ExternalQuotaSnapshot snapshot,
    })
  >
  _cache = {};
  final Map<String, int> _entryGen = {};
  int _cacheEpoch = 0;

  void clearCache() {
    _cacheEpoch++;
    _cache.clear();
    _entryGen.clear();
  }

  ExternalQuotaAdapter? _findAdapter(String providerId) {
    for (final a in adapters) {
      if (a.id == providerId) return a;
    }
    return null;
  }

  /// 并行拉取全部已配置的外部订阅账号（支持同平台多账号，彼此互不阻塞）。
  Future<List<ExternalQuotaSnapshot>> fetchAll(
    Map<String, ExternalQuotaProviderConfig> configs, {
    bool force = false,
  }) async {
    final activeIds = <String>{};
    final active = <(ExternalQuotaAdapter, ExternalQuotaProviderConfig)>[];
    for (final entry in configs.entries) {
      final cfg = entry.value;
      if (!cfg.isConfigured) continue;
      final adapter = _findAdapter(cfg.providerId);
      if (adapter == null) continue;
      var resolvedId = cfg.id.trim();
      if (resolvedId.isEmpty) {
        resolvedId = entry.key.trim().isNotEmpty ? entry.key.trim() : adapter.id;
      }
      if (activeIds.contains(resolvedId)) {
        var suffix = 2;
        while (activeIds.contains('$resolvedId-$suffix')) {
          suffix++;
        }
        resolvedId = '$resolvedId-$suffix';
      }
      activeIds.add(resolvedId);
      final normalizedCfg = resolvedId == cfg.id
          ? cfg
          : ExternalQuotaProviderConfig(
              id: resolvedId,
              providerId: cfg.providerId,
              apiKey: cfg.apiKey,
              baseUrl: cfg.baseUrl,
              label: cfg.label,
            );
      active.add((adapter, normalizedCfg));
    }
    // 清理已移除账号的旧缓存并递增其代际，防止在途慢请求复活已删账号。
    final staleIds = <String>{
      for (final id in _cache.keys)
        if (!activeIds.contains(id)) id,
      for (final id in _entryGen.keys)
        if (!activeIds.contains(id)) id,
    };
    for (final id in staleIds) {
      _entryGen[id] = (_entryGen[id] ?? 0) + 1;
      _cache.remove(id);
    }
    if (active.isEmpty) return const [];
    return Future.wait([
      for (final pair in active) fetchOne(pair.$1, pair.$2, force: force),
    ]);
  }

  Future<ExternalQuotaSnapshot> fetchOne(
    ExternalQuotaAdapter adapter,
    ExternalQuotaProviderConfig config, {
    bool force = false,
  }) async {
    final rawId = config.id.trim();
    final cacheId = rawId.isEmpty ? adapter.id : rawId;
    final trimmedBase = config.baseUrl.trim();
    final trimmedKey = config.apiKey.trim();
    final trimmedLabel = config.label.trim();
    final startEpoch = _cacheEpoch;
    final nowBefore = _now();
    if (!force) {
      final cached = _cache[cacheId];
      if (cached != null &&
          cached.providerId == adapter.id &&
          cached.baseUrl == trimmedBase &&
          cached.apiKey == trimmedKey &&
          cached.label == trimmedLabel &&
          cached.snapshot.ok &&
          nowBefore.difference(cached.snapshot.fetchedAt) < cacheTtl) {
        return cached.snapshot;
      }
    }
    final reqGen = (_entryGen[cacheId] ?? 0) + 1;
    _entryGen[cacheId] = reqGen;

    ExternalQuotaSnapshot fail(String error, {String? hint, DateTime? at}) =>
        ExternalQuotaSnapshot(
          entryId: cacheId,
          providerId: adapter.id,
          providerName: adapter.displayName,
          accountLabel: trimmedLabel,
          ok: false,
          fetchedAt: at ?? _now(),
          error: error,
          hint: hint,
        );

    final uri = resolveExternalQuotaUri(adapter, customBaseUrl: trimmedBase);
    if (uri == null) {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('接口地址无效（仅支持 HTTPS 地址）');
    }

    if (!isValidExternalApiKey(trimmedKey)) {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('API Key 格式无效（含换行或非法字符）', hint: adapter.authHint);
    }

    final headers = <String, String>{
      // 智谱额度接口不加 Bearer 前缀，其余平台均为标准 Bearer。
      'Authorization': adapter.useBearerAuth ? 'Bearer $trimmedKey' : trimmedKey,
      'Accept': 'application/json',
      'User-Agent': _userAgent,
      ...adapter.extraHeaders,
    };

    try {
      final res = await (_httpGet != null
          ? _httpGet(uri, headers).timeout(timeout)
          : _defaultGet(uri, headers, timeout));
      final fetchedAt = _now();
      if (res.statusCode == 401) {
        _evictIfCurrent(cacheId, startEpoch, reqGen);
        return fail(
          'API Key 失效或未授权（401）',
          hint: adapter.authHint,
          at: fetchedAt,
        );
      }
      if (res.statusCode == 403) {
        _evictIfCurrent(cacheId, startEpoch, reqGen);
        return fail('请求被拒绝（403），可能被风控拦截或 Key 无权限', at: fetchedAt);
      }
      if (res.statusCode == 404) {
        _evictIfCurrent(cacheId, startEpoch, reqGen);
        return fail('用量接口不存在（404），请检查接口地址', at: fetchedAt);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        _evictIfCurrent(cacheId, startEpoch, reqGen);
        return fail('服务返回异常（HTTP ${res.statusCode}）', at: fetchedAt);
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        throw const FormatException('root is not object');
      }
      final snapshot = adapter
          .parseResponse(decoded.cast<String, dynamic>(), fetchedAt)
          .withAccount(entryId: cacheId, accountLabel: trimmedLabel);
      if (startEpoch == _cacheEpoch && _entryGen[cacheId] == reqGen) {
        _cache[cacheId] = (
          providerId: adapter.id,
          baseUrl: trimmedBase,
          apiKey: trimmedKey,
          label: trimmedLabel,
          epoch: startEpoch,
          snapshot: snapshot,
        );
      }
      return snapshot;
    } on ExternalQuotaAuthException catch (e) {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail(e.message, hint: adapter.authHint);
    } on TimeoutException {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('请求超时，请检查网络后重试');
    } on FormatException {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('返回数据格式无法识别');
    } on SocketException {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('网络连接失败，请稍后重试');
    } catch (_) {
      _evictIfCurrent(cacheId, startEpoch, reqGen);
      return fail('查询失败，请稍后重试');
    }
  }

  void _evictIfCurrent(String cacheId, int startEpoch, int reqGen) {
    if (startEpoch == _cacheEpoch && _entryGen[cacheId] == reqGen) {
      _cache.remove(cacheId);
    }
  }

  Future<({int statusCode, String body})> _defaultGet(
    Uri uri,
    Map<String, String> headers,
    Duration totalTimeout,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    var timedOut = false;
    final deadline = Timer(totalTimeout, () {
      timedOut = true;
      client.close(force: true);
    });
    try {
      final req = await client.getUrl(uri);
      // 禁用自动重定向，防止 Authorization 头被跳到非 HTTPS 域名。
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      final resp = await req.close();
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > _maxBodyBytes) {
          throw const FormatException('response too large');
        }
        bytes.addAll(chunk);
      }
      return (
        statusCode: resp.statusCode,
        body: utf8.decode(bytes, allowMalformed: true),
      );
    } catch (e) {
      if (timedOut) {
        throw TimeoutException('external quota request timed out', totalTimeout);
      }
      rethrow;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}

/// 进程级共享外部配额客户端（供用量速览与全局缓存失效链路共用，避免跨层循环依赖）。
final ExternalQuotaClient sharedExternalQuotaClient = ExternalQuotaClient();
