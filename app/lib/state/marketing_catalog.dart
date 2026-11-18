import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/l10n.dart';
import 'app_state.dart';

/// 桌面端版本兜底值（仅当 bootstrap 未下发 desktopAppVersion 时使用）。
/// 正常路径：AppState.desktopAppVersion（与关于页「桌面端 3.18.2」同源）。
const kZCodeDesktopAppVersion = '3.18.2';

/// 营销投放里的可领取套餐（来自 banner.args.zcode_plan）。
class MarketingPlan {
  final String campaignId;
  final String planId;
  final String name;
  final String modelName;
  final num grantUnits;
  final String unitType;
  final DateTime? endsAt;
  final DateTime? effectiveAt;

  const MarketingPlan({
    required this.campaignId,
    required this.planId,
    required this.name,
    required this.modelName,
    required this.grantUnits,
    required this.unitType,
    required this.endsAt,
    required this.effectiveAt,
  });

  String get amountNumberLabel {
    final value = grantUnits.truncate();
    final digits = value.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return '${value < 0 ? '-' : ''}$buffer';
  }

  String get unitLabel =>
      unitType.toLowerCase() == 'token' ? 'tokens' : unitType;

  String get amountLabel => '$amountNumberLabel $unitLabel';

  String get endsAtLabel {
    final value = endsAt;
    if (value == null) return '';
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.month}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _Identity {
  final String jwt;
  final String deviceMid;
  final String version;
  final String platform;
  final String locale;

  const _Identity({
    required this.jwt,
    required this.deviceMid,
    required this.version,
    required this.platform,
    required this.locale,
  });
}

/// 营销投放目录：直连 ZCode 营销接口（PC 的 marketing-touch 通道未对
/// 远程客户端开放），身份取本机账号 JWT + 桌面 device mid + 桌面版本/
/// 平台请求头。领取动作仍交给 PC 执行（claimManualPlan）。
class MarketingCatalog {
  MarketingCatalog._();

  static final instance = MarketingCatalog._();
  static const _baseUrl = 'https://zcode.z.ai';
  static const _ttl = Duration(minutes: 10);

  MarketingPlan? plan;
  DateTime? fetchedAt;
  bool _loading = false;
  Future<MarketingPlan?>? _inFlight;
  String? _deviceMid;
  String? _platform;
  String? _desktopVersion;
  int _seq = 1;

  /// 10 分钟缓存；force=true 立即重查。
  Future<MarketingPlan?> ensureFresh(AppState app, {bool force = false}) {
    final fetched = fetchedAt;
    if (!force &&
        fetched != null &&
        DateTime.now().difference(fetched) < _ttl) {
      return Future.value(plan);
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _fetch(app).whenComplete(() {
      _loading = false;
      _inFlight = null;
    });
    _loading = true;
    _inFlight = future;
    return future;
  }

  bool get loading => _loading;

  void clear() {
    plan = null;
    fetchedAt = null;
  }

  Future<MarketingPlan?> _fetch(AppState app) async {
    try {
      final identity = await _resolveIdentity(app);
      if (identity == null) return null;
      var found = await _query(identity);
      if (found == null) {
        // 手机 JWT 与桌面可能不是同一会话：空结果时用桌面登录凭据兜底一次。
        String? desktopJwt;
        try {
          desktopJwt = await app.loadCredential('zcodejwttoken');
        } catch (_) {}
        if (desktopJwt != null &&
            desktopJwt.isNotEmpty &&
            desktopJwt != identity.jwt) {
          found = await _query(
            _Identity(
              jwt: desktopJwt,
              deviceMid: identity.deviceMid,
              version: identity.version,
              platform: identity.platform,
              locale: identity.locale,
            ),
          );
        }
      }
      plan = found;
      fetchedAt = DateTime.now();
      return found;
    } catch (_) {
      fetchedAt = DateTime.now();
      return null;
    }
  }

  Future<_Identity?> _resolveIdentity(AppState app) async {
    final jwt = await app.accountStore.readJwt();
    if (jwt == null || jwt.trim().isEmpty) return null;
    var mid = _deviceMid;
    if (mid == null) {
      try {
        final info = await app.systemInfo();
        final home = info?['homedir'];
        _platform = '${info?['platform'] ?? 'linux'}';
        if (home is String && home.trim().isNotEmpty) {
          for (final path in [
            '$home/.zcode/v2/telemetry-state.json',
            '$home/.zcode/cli/telemetry-state.json',
          ]) {
            try {
              final res = await app.readTextFileAbsolute(path);
              final content = res?['content'];
              if (content is! String || content.isEmpty) continue;
              final decoded = jsonDecode(content);
              if (decoded is Map && decoded['deviceMid'] is String) {
                final value = '${decoded['deviceMid']}'.trim();
                if (value.isNotEmpty) {
                  mid = value;
                  break;
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      mid ??= _uuidV4();
      _deviceMid = mid;
    }
    return _Identity(
      jwt: jwt,
      deviceMid: mid,
      version: await _resolveDesktopVersion(app),
      platform: '${_platform ?? 'linux'}-x64',
      locale: L10n.resolvedLocale,
    );
  }

  Future<String> _resolveDesktopVersion(AppState app) async {
    // 桌面端版本由 bootstrap 下发（workspace_controller.desktopAppVersion，
    // 关于页副标题「桌面端 3.18.2」同源）。每次读取，桌面升级后即时生效。
    final fromApp = app.desktopAppVersion?.trim();
    if (fromApp != null && fromApp.isNotEmpty) return fromApp;
    final cached = _desktopVersion;
    if (cached != null) return cached;
    var version = kZCodeDesktopAppVersion;
    try {
      final bridge = app.bridgeInfo();
      for (final key in const [
        'desktopVersion',
        'appVersion',
        'version',
        'hostVersion',
      ]) {
        final value = bridge?[key];
        if (value is String && value.trim().isNotEmpty) {
          version = value.trim();
          break;
        }
      }
    } catch (_) {}
    _desktopVersion = version;
    return version;
  }

  Map<String, String> _headers(_Identity identity) => {
    'Authorization': 'Bearer ${identity.jwt}',
    'X-Device-Mid': identity.deviceMid,
    'X-Client-Language': identity.locale,
    'X-ZCode-App-Version': identity.version,
    'User-Agent': 'ZCode/${identity.version}',
    'HTTP-Referer': _baseUrl,
    'X-Title': 'Z Code@electron',
    'X-Platform': identity.platform,
    'X-Release-Channel': 'production',
    'X-Os-Category': identity.platform.split('-').first,
    'X-Client-Timezone': 'Asia/Shanghai',
    'Accept': 'application/json',
  };

  Future<MarketingPlan?> _query(_Identity identity) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse(
        '$_baseUrl/api/v1/marketing/touch?seq=${_seq++}',
      );
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      _headers(identity).forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(body);
      final data = decoded is Map ? decoded['data'] : null;
      final deliveries = data is Map ? data['deliveries'] : null;
      if (deliveries is! List) return null;
      for (final raw in deliveries) {
        if (raw is! Map) continue;
        if ('${raw['resource_position'] ?? ''}' != 'banner') continue;
        final campaignId = '${raw['campaign_id'] ?? ''}'.trim();
        final banner = raw['banner'];
        if (banner is! Map) continue;
        final buttons = banner['buttons'];
        String? planId;
        if (buttons is List) {
          for (final button in buttons) {
            if (button is! Map) continue;
            final action = button['action'];
            if (action is! Map || action['type'] != 'claim_zcode_plan') {
              continue;
            }
            final args = action['args'];
            if (args is Map) {
              final value = '${args['plan_id'] ?? ''}'.trim();
              if (value.isNotEmpty) planId = value;
            }
          }
        }
        final background = banner['background'];
        final planInfo = background is Map && background['args'] is Map
            ? (background['args'] as Map)['zcode_plan']
            : null;
        if (planId == null || planInfo is! Map) continue;
        final entitlements = planInfo['entitlements'];
        Map? entitlement;
        if (entitlements is List) {
          for (final item in entitlements) {
            if (item is Map) {
              entitlement = item;
              break;
            }
          }
        }
        final endsAtRaw = planInfo['ends_at'];
        final endsAt = endsAtRaw is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (endsAtRaw * 1000).round(),
                isUtc: true,
              )
            : null;
        final grant = entitlement?['grant_units'];
        final effectiveRaw = entitlement?['effective_at'];
        final effectiveAt = effectiveRaw is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (effectiveRaw * 1000).round(),
                isUtc: true,
              )
            : null;
        return MarketingPlan(
          campaignId: campaignId,
          planId: planId,
          name: '${planInfo['name'] ?? '限时体验套餐'}',
          modelName: '${entitlement?['show_name'] ?? ''}',
          grantUnits: grant is num ? grant : 0,
          unitType: '${entitlement?['unit_type'] ?? 'token'}',
          endsAt: endsAt,
          effectiveAt: effectiveAt,
        );
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 卡片动作回执（confirm/cancel），失败静默。
  Future<void> report(AppState app, MarketingPlan plan, String actionType) async {
    try {
      final identity = await _resolveIdentity(app);
      if (identity == null) return;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final req = await client
            .postUrl(
              Uri.parse('$_baseUrl/api/v1/marketing/touch/action'),
            )
            .timeout(const Duration(seconds: 10));
        _headers(identity).forEach(req.headers.set);
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'campaign_id': plan.campaignId,
            'action_type': actionType,
          }),
        );
        await req.close().timeout(const Duration(seconds: 15));
      } finally {
        client.close(force: true);
      }
    } catch (_) {}
  }
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
