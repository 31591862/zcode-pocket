// 首页「用量速览」弹层：
// 1. 默认极简规则：自动展示官方 GLM Coding Plan，并并行探测 GLM Start Plan
//    （如夜间 3 亿 GLM-5.3-Flash 福利包——有激活额度时自动并排显示，无福利包时完全隐身）；
//    未添加外部订阅时主面板零推广占位，对不需要的用户完全无感；
// 2. 右上角轻量「+」入口原位切换「自定义用量速览」：
//    - 统一列表拖动排序 + 独立开关控制显隐（非 GLM 用户可关闭官方卡片跳过 RPC；
//      外部账号可临时隐藏不删 Key）；
//    - 外部订阅按需添加（支持同平台多账号与备注名，加密存本机 UiPrefs），
//      附可折叠「安全说明 · 开源可审」与实时直连 HTTPS 地址展示打消 Key 顾虑。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/external_quota.dart';
import '../core/l10n.dart';
import '../core/localized_text.dart';
import '../core/official_account_quota.dart';
import '../core/theme.dart';
import '../core/usage_format.dart';
import '../core/usage_timezone.dart';
import '../state/account_store.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../transport/channel_client.dart';
import '../transport/z_transport.dart';
import 'usage_page.dart';

/// 打开首页「用量速览」弹层。
Future<void> showUsageQuickSheet(
  BuildContext context, {
  ExternalQuotaClient? externalClient,
  OfficialStartPlanDirectClient? startPlanClient,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _UsageQuickSheet(
      externalClient: externalClient ?? sharedExternalQuotaClient,
      startPlanClient: startPlanClient ?? sharedStartPlanDirectClient,
    ),
  );
}

/// 打开「自定义用量速览与外部额度查询配置」弹层（返回 true 表示配置已更新）。
Future<bool> showExternalQuotaConfigSheet(BuildContext context) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _UsageQuickCustomizeSheet(),
  );
  if (changed == true) {
    sharedExternalQuotaClient.clearCache();
    sharedStartPlanDirectClient.clearCache();
  }
  return changed == true;
}

class _AccountCodingSlot {
  const _AccountCodingSlot({
    this.loading = false,
    this.error,
    this.ent,
    this.todayCp,
    this.cached,
    this.family = 'bigmodel',
    this.isOnline = false,
    this.quietOffline = false,
  });

  final bool loading;
  final String? error;
  final Map<String, dynamic>? ent;
  final Map<String, dynamic>? todayCp;
  final CachedOfficialQuota? cached;
  final String family;
  final bool isOnline;
  final bool quietOffline;
}

class _AccountStartSlot {
  const _AccountStartSlot({
    this.loading = false,
    this.ent,
    this.family = 'bigmodel',
    this.isDirect = false,
  });

  final bool loading;
  final Map<String, dynamic>? ent;
  final String family;
  final bool isDirect;
}

class _UsageQuickSheet extends StatefulWidget {
  const _UsageQuickSheet({
    required this.externalClient,
    required this.startPlanClient,
  });

  final ExternalQuotaClient externalClient;
  final OfficialStartPlanDirectClient startPlanClient;

  @override
  State<_UsageQuickSheet> createState() => _UsageQuickSheetState();
}

/// 按活跃账号优先读取去重后的账号列表（供速览页与独立自定义弹层共用）。
Future<List<StoredAccount>> _loadOrderedAccountsFor(AppState app) async {
  try {
    final raw = await app.accountStore.listAccounts();
    final seen = <String>{};
    final deduped = <StoredAccount>[];
    for (final acc in raw) {
      final id = acc.id.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      deduped.add(acc);
    }
    final activeId = app.activeAccountId;
    if (activeId != null && deduped.length > 1) {
      final idx = deduped.indexWhere((a) => a.id == activeId);
      if (idx > 0) {
        final active = deduped.removeAt(idx);
        deduped.insert(0, active);
      }
    }
    return deduped;
  } catch (_) {
    return const [];
  }
}

class _UsageQuickSheetState extends State<_UsageQuickSheet> {
  // 多账号去重列表（按活跃账号优先排序；<=1 个账号时保持单账号零噪音形态）。
  List<StoredAccount> _accounts = const [];
  bool _accountsLoading = true;
  bool _accountsLoaded = false;
  int _accountsGen = 0;
  bool get _isMultiAccount => _accounts.length > 1;

  // 单账号官方 GLM Coding Plan 状态
  bool _codingLoading = false;
  String? _codingError;
  Map<String, dynamic>? _codingEnt;
  Map<String, dynamic>? _codingToday;
  CachedOfficialQuota? _codingCached;
  String _codingFamily = 'bigmodel';
  String? _manualCodingFamily;
  int _codingGen = 0;

  // 单账号官方 GLM Start Plan（福利包 / Start 额度）独立状态
  bool _startLoading = false;
  String? _startError;
  Map<String, dynamic>? _startEnt;
  String _startFamily = 'bigmodel';
  String? _manualStartFamily;
  bool _startDirect = false;
  int _startGen = 0;

  // 多账号按 accountId 隔离的官方状态表与独立代际（切单个账号的来源绝不打断其余账号在途请求）
  final Map<String, _AccountCodingSlot> _multiCoding = {};
  final Map<String, _AccountStartSlot> _multiStart = {};
  final Map<String, int> _multiCodingGen = {};
  final Map<String, int> _multiStartGen = {};
  final Map<String, String> _manualMultiCodingFamily = {};
  final Map<String, String> _manualMultiStartFamily = {};

  // 外部订阅状态（全局手机侧，与多电脑/多账号切换解耦）
  bool _externalLoading = false;
  List<ExternalQuotaSnapshot> _externalSnapshots = const [];
  int _externalGen = 0;

  bool _editingConfig = false;
  bool _configSaving = false;
  DateTime? _updatedAt;

  bool _depsInitialized = false;
  Object? _lastBridge;
  String? _lastAccountKey;
  int _lastAccountRev = 0;
  String _lastOnlineBridgesSig = '';

  bool get _anyLoading =>
      _accountsLoading ||
      _codingLoading ||
      _startLoading ||
      _externalLoading ||
      _multiCoding.values.any((s) => s.loading) ||
      _multiStart.values.any((s) => s.loading);

  int _nextMultiCodingGen(String accountId) {
    final next = (_multiCodingGen[accountId] ?? 0) + 1;
    _multiCodingGen[accountId] = next;
    return next;
  }

  int _nextMultiStartGen(String accountId) {
    final next = (_multiStartGen[accountId] ?? 0) + 1;
    _multiStartGen[accountId] = next;
    return next;
  }

  List<String> _officialCardIdsFor(List<StoredAccount> accounts) {
    if (accounts.length <= 1) {
      return const [kUsageCardOfficialCoding, kUsageCardOfficialStart];
    }
    return [
      for (final a in accounts) ...[
        usageCardOfficialCodingId(a.id),
        usageCardOfficialStartId(a.id),
      ],
    ];
  }

  String _onlineBridgesSignature(AppState app) {
    if (_accounts.isEmpty) return '';
    return [
      for (final a in _accounts)
        '${a.id}:${identityHashCode(app.onlineBridgeForAccount(a.id))}',
    ].join(',');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    final profile = app.activeProfile;
    final accId = profile is AccountV2Profile ? (profile.accountId ?? '') : '';
    final accountKey = '${profile?.deviceSid ?? ''}|$accId';
    final accountRev = app.accountChangeRevision;
    final bridgesSig = _onlineBridgesSignature(app);
    if (!_depsInitialized) {
      _depsInitialized = true;
      _lastBridge = bridge;
      _lastAccountKey = accountKey;
      _lastAccountRev = accountRev;
      _lastOnlineBridgesSig = bridgesSig;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadAll(force: false);
      });
      return;
    }
    final accountChanged =
        _lastAccountKey != accountKey || _lastAccountRev != accountRev;
    final bridgeChanged =
        !identical(_lastBridge, bridge) || _lastOnlineBridgesSig != bridgesSig;
    _lastBridge = bridge;
    _lastAccountKey = accountKey;
    _lastAccountRev = accountRev;
    _lastOnlineBridgesSig = bridgesSig;
    if (accountChanged) {
      _manualCodingFamily = null;
      _manualStartFamily = null;
      _manualMultiCodingFamily.clear();
      _manualMultiStartFamily.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reloadOfficialBoth();
      });
    } else if (bridgeChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reloadOfficialBoth();
      });
    }
  }

  String _detectDefaultFamily(AppState app, {StoredAccount? account}) {
    final accProvider = account?.provider.toLowerCase() ?? '';
    if (accProvider.contains('zai')) return 'zai';
    if (accProvider.contains('bigmodel') || accProvider.contains('glm')) {
      return 'bigmodel';
    }
    String? convFamily;
    for (final state in app.conversationStates.values) {
      final cfg = state.snapshot?['config'];
      final provider = cfg is Map ? '${cfg['provider'] ?? ''}' : '';
      final lp = provider.toLowerCase();
      if (lp.contains('zai')) {
        convFamily = 'zai';
      } else if (convFamily == null &&
          (lp.contains('bigmodel') || lp.contains('glm'))) {
        convFamily = 'bigmodel';
      }
    }
    final lastModel = app.uiPrefs.lastModel ?? '';
    final lastProvider = lastModel.contains('/')
        ? lastModel.split('/').first
        : '';
    final lastLower = lastProvider.toLowerCase();
    if (lastLower.contains('zai')) return 'zai';
    if (lastLower.contains('bigmodel') || lastLower.contains('glm')) {
      return 'bigmodel';
    }
    return convFamily ?? 'bigmodel';
  }

  Future<void> _reloadOfficialBoth({bool force = false}) async {
    if (!mounted) return;
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final aGen = ++_accountsGen;
    final cGen = ++_codingGen;
    final sGen = ++_startGen;
    if (!_accountsLoaded) {
      setState(() => _accountsLoading = true);
    }
    final accounts = await _loadOrderedAccountsFor(app);
    if (!mounted || aGen != _accountsGen) return;

    if (accounts.length > 1) {
      await _loadMultiAccountOfficial(
        app,
        accounts,
        layout,
        force: force,
      );
      if (mounted && aGen == _accountsGen) {
        setState(() => _updatedAt = DateTime.now());
      }
      return;
    }

    final singleAccount = accounts.isNotEmpty ? accounts.first : null;
    final singleAccountId = app.activeAccountId ?? singleAccount?.id;
    final codingOn = layout.isOfficialCardVisible(
      kUsageCardOfficialCoding,
      isMultiAccount: false,
      singleAccountId: singleAccountId,
    );
    final startOn = layout.isOfficialCardVisible(
      kUsageCardOfficialStart,
      isMultiAccount: false,
      singleAccountId: singleAccountId,
    );
    setState(() {
      _accounts = accounts;
      _accountsLoading = false;
      _accountsLoaded = true;
      _lastOnlineBridgesSig = _onlineBridgesSignature(app);
      _multiCoding.clear();
      _multiStart.clear();
      _codingLoading = codingOn;
      _codingError = null;
      _codingCached = null;
      _startLoading = startOn;
      _startError = null;
      _startDirect = false;
      if (!codingOn) {
        _codingEnt = null;
        _codingToday = null;
      }
      if (!startOn) {
        _startEnt = null;
      }
    });
    await Future.wait([
      if (codingOn)
        _loadCoding(
          app,
          cGen,
          layout,
          accountId: singleAccountId,
          account: singleAccount,
        ),
      if (startOn)
        _loadStart(
          app,
          sGen,
          layout,
          accountId: singleAccountId,
          account: singleAccount,
          force: force,
        ),
    ]);
    if (mounted && (cGen == _codingGen || sGen == _startGen)) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _selectCodingFamily(String family) async {
    if (_manualCodingFamily == family &&
        _codingFamily == family &&
        _codingError == null) {
      return;
    }
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final gen = ++_codingGen;
    final singleAccount = _accounts.isNotEmpty ? _accounts.first : null;
    final singleAccountId = app.activeAccountId ?? singleAccount?.id;
    setState(() {
      _manualCodingFamily = family;
      _codingFamily = family;
      _codingLoading = true;
      _codingError = null;
    });
    await _loadCoding(
      app,
      gen,
      layout,
      accountId: singleAccountId,
      account: singleAccount,
    );
    if (mounted && gen == _codingGen) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _selectStartFamily(String family) async {
    if (_manualStartFamily == family &&
        _startFamily == family &&
        _startError == null) {
      return;
    }
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final gen = ++_startGen;
    final singleAccount = _accounts.isNotEmpty ? _accounts.first : null;
    final singleAccountId = app.activeAccountId ?? singleAccount?.id;
    setState(() {
      _manualStartFamily = family;
      _startFamily = family;
      _startLoading = true;
      _startError = null;
    });
    await _loadStart(
      app,
      gen,
      layout,
      accountId: singleAccountId,
      account: singleAccount,
      force: true,
    );
    if (mounted && gen == _startGen) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _selectMultiCodingFamily(
    StoredAccount account,
    String family,
  ) async {
    final prev = _multiCoding[account.id];
    if (_manualMultiCodingFamily[account.id] == family &&
        prev != null &&
        prev.family == family &&
        prev.error == null) {
      return;
    }
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final gen = _nextMultiCodingGen(account.id);
    setState(() {
      _manualMultiCodingFamily[account.id] = family;
      _multiCoding[account.id] = _AccountCodingSlot(
        loading: true,
        family: family,
        isOnline: app.onlineBridgeForAccount(account.id) != null,
      );
    });
    await _loadAccountCodingSlot(app, account, gen, layout);
    if (mounted && gen == _multiCodingGen[account.id]) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _selectMultiStartFamily(
    StoredAccount account,
    String family,
  ) async {
    final prev = _multiStart[account.id];
    if (_manualMultiStartFamily[account.id] == family &&
        prev != null &&
        prev.family == family) {
      return;
    }
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final gen = _nextMultiStartGen(account.id);
    setState(() {
      _manualMultiStartFamily[account.id] = family;
      _multiStart[account.id] = _AccountStartSlot(
        loading: true,
        family: family,
      );
    });
    await _loadAccountStartSlot(app, account, gen, layout, force: true);
    if (mounted && gen == _multiStartGen[account.id]) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _loadAll({required bool force}) async {
    if (!mounted) return;
    final app = AppStateScope.of(context);
    final layout = app.uiPrefs.usageQuickLayout;
    final visibleExternals = <String, ExternalQuotaProviderConfig>{
      for (final e in app.uiPrefs.externalQuotas.entries)
        if (layout.isVisible(usageCardExternalId(e.value.id))) e.key: e.value,
    };
    final aGen = ++_accountsGen;
    final cGen = ++_codingGen;
    final sGen = ++_startGen;
    final eGen = ++_externalGen;
    setState(() {
      _accountsLoading = true;
      _externalLoading = visibleExternals.isNotEmpty;
    });
    // 外部额度查询不依赖 ZCode 账号列表，立即并行发起——防止 _loadOrderedAccountsFor
    // 期间被 _reloadOfficialBoth 递增 _accountsGen 打断时，_externalLoading 永久卡在 true。
    final externalFuture = _loadExternal(
      visibleExternals,
      eGen,
      force: force,
    );
    final accounts = await _loadOrderedAccountsFor(app);
    if (!mounted || aGen != _accountsGen) {
      await externalFuture;
      return;
    }

    if (accounts.length > 1) {
      await Future.wait([
        _loadMultiAccountOfficial(
          app,
          accounts,
          layout,
          force: force,
        ),
        externalFuture,
      ]);
      if (mounted && (aGen == _accountsGen || eGen == _externalGen)) {
        setState(() => _updatedAt = DateTime.now());
      }
      return;
    }

    final singleAccount = accounts.isNotEmpty ? accounts.first : null;
    final singleAccountId = app.activeAccountId ?? singleAccount?.id;
    final codingOn = layout.isOfficialCardVisible(
      kUsageCardOfficialCoding,
      isMultiAccount: false,
      singleAccountId: singleAccountId,
    );
    final startOn = layout.isOfficialCardVisible(
      kUsageCardOfficialStart,
      isMultiAccount: false,
      singleAccountId: singleAccountId,
    );
    setState(() {
      _accounts = accounts;
      _accountsLoading = false;
      _accountsLoaded = true;
      _lastOnlineBridgesSig = _onlineBridgesSignature(app);
      _multiCoding.clear();
      _multiStart.clear();
      _codingLoading = codingOn;
      _codingError = null;
      _codingCached = null;
      _startLoading = startOn;
      _startError = null;
      _startDirect = false;
      if (!codingOn) {
        _codingEnt = null;
        _codingToday = null;
      }
      if (!startOn) {
        _startEnt = null;
      }
    });
    await Future.wait([
      if (codingOn)
        _loadCoding(
          app,
          cGen,
          layout,
          accountId: singleAccountId,
          account: singleAccount,
        ),
      if (startOn)
        _loadStart(
          app,
          sGen,
          layout,
          accountId: singleAccountId,
          account: singleAccount,
          force: force,
        ),
      externalFuture,
    ]);
    if (mounted &&
        (cGen == _codingGen || sGen == _startGen || eGen == _externalGen)) {
      setState(() => _updatedAt = DateTime.now());
    }
  }

  Future<void> _loadMultiAccountOfficial(
    AppState app,
    List<StoredAccount> accounts,
    UsageQuickLayoutPrefs layout, {
    required bool force,
  }) async {
    final validIds = {for (final a in accounts) a.id};
    final codingGens = <String, int>{};
    final startGens = <String, int>{};
    setState(() {
      _accounts = accounts;
      _accountsLoading = false;
      _accountsLoaded = true;
      _lastOnlineBridgesSig = _onlineBridgesSignature(app);
      _codingLoading = false;
      _startLoading = false;
      _multiCoding.removeWhere((k, _) => !validIds.contains(k));
      _multiStart.removeWhere((k, _) => !validIds.contains(k));
      for (final acc in accounts) {
        final cCardId = usageCardOfficialCodingId(acc.id);
        final sCardId = usageCardOfficialStartId(acc.id);
        if (layout.isOfficialCardVisible(cCardId, isMultiAccount: true)) {
          codingGens[acc.id] = _nextMultiCodingGen(acc.id);
          _multiCoding[acc.id] = _AccountCodingSlot(
            loading: true,
            family: _manualMultiCodingFamily[acc.id] ??
                _detectDefaultFamily(app, account: acc),
            isOnline: app.onlineBridgeForAccount(acc.id) != null,
          );
        } else {
          _multiCoding.remove(acc.id);
        }
        if (layout.isOfficialCardVisible(sCardId, isMultiAccount: true)) {
          startGens[acc.id] = _nextMultiStartGen(acc.id);
          _multiStart[acc.id] = _AccountStartSlot(
            loading: true,
            family: _manualMultiStartFamily[acc.id] ??
                _detectDefaultFamily(app, account: acc),
          );
        } else {
          _multiStart.remove(acc.id);
        }
      }
    });
    await Future.wait([
      for (final acc in accounts) ...[
        if (codingGens.containsKey(acc.id))
          _loadAccountCodingSlot(app, acc, codingGens[acc.id]!, layout),
        if (startGens.containsKey(acc.id))
          _loadAccountStartSlot(
            app,
            acc,
            startGens[acc.id]!,
            layout,
            force: force,
          ),
      ],
    ]);
  }

  Future<Map<String, dynamic>?> _callEnt(
    dynamic bridge,
    String fam,
    String kind,
  ) async {
    final res = await bridge.channels
        .call(
          Channels.usageStats,
          'getEntitlementSnapshot',
          [
            {
              'includeSubscription': true,
              ...codingPlanScope(fam, kind),
              'allowDisabledPreferredProvider': true,
            },
          ],
          timeout: const Duration(seconds: 20),
        )
        .timeout(const Duration(seconds: 12));
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  Future<Map<String, dynamic>?> _callToday(
    dynamic bridge,
    String fam,
    String kind,
    String? tz,
  ) async {
    try {
      final res = await bridge.channels
          .call(
            Channels.usageStats,
            'getCodingPlanUsageSnapshot',
            [
              {
                'range': 'today',
                ...codingPlanScope(fam, kind),
                if (tz != null) 'timeZone': tz,
              },
            ],
            timeout: const Duration(seconds: 20),
          )
          .timeout(const Duration(seconds: 12));
      return res is Map ? res.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  String _reasonOf(Map<String, dynamic>? snap) =>
      '${snap?['unavailableReason'] ?? ''}'.trim();

  bool _hasOfficialQuotaData(Map<String, dynamic>? ent) {
    if (ent == null) return false;
    if (_reasonOf(ent).isNotEmpty) return false;
    final quota = ent['quota'] is Map
        ? (ent['quota'] as Map).cast<String, dynamic>()
        : null;
    final limits = quota?['limits'] is List ? quota!['limits'] as List : null;
    final mcpQuota = ent['mcpQuota'] is Map
        ? (ent['mcpQuota'] as Map).cast<String, dynamic>()
        : null;
    final mcpAggregate = mcpQuota?['aggregate'] is Map
        ? (mcpQuota!['aggregate'] as Map).cast<String, dynamic>()
        : null;
    final hasAnyLimit =
        findQuotaLimit(limits, tokenKind: true, unit: 3, number: 5) != null ||
        findQuotaLimit(limits, tokenKind: true, unit: 6) != null ||
        findQuotaLimit(limits, tokenKind: false) != null ||
        mcpAggregate != null;
    if (hasAnyLimit) return true;
    return extractStartPlanWindows(ent).isNotEmpty;
  }

  /// 从 `getCodingPlanUsageSnapshot` 提取今日活跃摘要：
  /// 官方桌面契约位于 `todayCp['activity']['summary']`（峰值键为 `peakDailyTokens`）；
  /// 同步兼容历史/轻量夹具的顶层 `todayCp['summary']` 与 `peakTokens`。
  Map<String, dynamic>? _extractTodaySummary(Map<String, dynamic>? todayCp) {
    if (todayCp == null) return null;
    final activity = todayCp['activity'];
    if (activity is Map && activity['summary'] is Map) {
      return (activity['summary'] as Map).cast<String, dynamic>();
    }
    final direct = todayCp['summary'];
    return direct is Map ? direct.cast<String, dynamic>() : null;
  }

  CachedOfficialQuota? _buildCodingCacheSnapshot({
    required String accountId,
    required String family,
    required Map<String, dynamic>? ent,
    required Map<String, dynamic>? todayCp,
  }) {
    if (accountId.trim().isEmpty || ent == null || _reasonOf(ent).isNotEmpty) {
      return null;
    }
    final quota = ent['quota'] is Map
        ? (ent['quota'] as Map).cast<String, dynamic>()
        : null;
    final limits = quota?['limits'] is List ? quota!['limits'] as List : null;
    final mcpQuota = ent['mcpQuota'] is Map
        ? (ent['mcpQuota'] as Map).cast<String, dynamic>()
        : null;
    final mcpAggregate = mcpQuota?['aggregate'] is Map
        ? (mcpQuota!['aggregate'] as Map).cast<String, dynamic>()
        : null;
    final fiveH = findQuotaLimit(limits, tokenKind: true, unit: 3, number: 5);
    final weekly = findQuotaLimit(limits, tokenKind: true, unit: 6);
    final toolLimit = findQuotaLimit(limits, tokenKind: false);

    int? resetMsOf(Map<String, dynamic>? m) {
      final raw = m?['nextResetTime'];
      return raw is num && raw.isFinite ? raw.toInt() : null;
    }

    final windows = <CachedQuotaWindow>[
      if (fiveH != null)
        CachedQuotaWindow(
          label: '5 小时窗口',
          remainingPercent: quotaRemainingPercent(fiveH),
          resetAtMs: resetMsOf(fiveH),
          colorSlot: 0,
        ),
      if (weekly != null)
        CachedQuotaWindow(
          label: '每周配额',
          remainingPercent: quotaRemainingPercent(weekly),
          resetAtMs: resetMsOf(weekly),
          colorSlot: 1,
        ),
      if (toolLimit != null)
        CachedQuotaWindow(
          label: '每月工具调用',
          remainingPercent: quotaRemainingPercent(toolLimit),
          resetAtMs: resetMsOf(toolLimit),
          colorSlot: 2,
        ),
      if (mcpAggregate != null)
        CachedQuotaWindow(
          label: 'MCP 额度',
          remainingPercent: quotaRemainingPercent(mcpAggregate),
          resetAtMs: resetMsOf(mcpAggregate),
          colorSlot: 5,
        ),
    ];
    if (windows.isEmpty) return null;

    final levelRaw = quota?['level'];
    final levelStr = levelRaw is String ? levelRaw : null;
    final subMap = ent['subscription'] is Map
        ? (ent['subscription'] as Map).cast<String, dynamic>()
        : null;
    final subDetails = subMap?['details'] is List
        ? subMap!['details'] as List
        : null;
    final firstDetail =
        (subDetails != null && subDetails.isNotEmpty && subDetails.first is Map)
        ? (subDetails.first as Map).cast<String, dynamic>()
        : null;
    final productNameRaw = firstDetail?['productName'];
    final productNameStr = productNameRaw is String ? productNameRaw : null;
    final planName =
        formatPlanName(level: levelStr, productName: productNameStr) ??
        'GLM Coding Plan';

    final summary = _extractTodaySummary(todayCp);
    final rawTotal = summary?['totalTokens'];
    final rawPeak = summary?['peakDailyTokens'] ?? summary?['peakTokens'];
    return CachedOfficialQuota(
      accountId: accountId.trim(),
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
      family: family,
      planName: planName,
      windows: windows,
      todayTotalTokens: rawTotal is num && rawTotal.isFinite ? rawTotal : null,
      todayPeakTokens: rawPeak is num && rawPeak.isFinite ? rawPeak : null,
    );
  }

  Future<void> _loadCoding(
    AppState app,
    int gen,
    UsageQuickLayoutPrefs layout, {
    String? accountId,
    StoredAccount? account,
  }) async {
    final bridge =
        app.bridge ??
        (accountId != null ? app.onlineBridgeForAccount(accountId) : null);
    if (bridge == null) {
      final cached = accountId != null
          ? app.uiPrefs.officialQuotaFor(accountId)
          : null;
      if (!mounted || gen != _codingGen) return;
      setState(() {
        _codingLoading = false;
        _codingEnt = null;
        _codingToday = null;
        _codingCached = cached;
        _codingError = cached == null ? '桌面离线，暂无法读取官方订阅额度' : null;
      });
      return;
    }

    final pinned =
        _manualCodingFamily ??
        (layout.codingScope == 'auto' ? null : layout.codingScope);
    var family = pinned ?? _detectDefaultFamily(app, account: account);
    final cacheEpoch = accountId != null
        ? app.uiPrefs.officialQuotaCacheEpoch(accountId)
        : null;

    try {
      final tz = await readDeviceTimeZone();
      if (!mounted || gen != _codingGen) return;
      var ent = await _callEnt(bridge, family, 'individual-coding-plan');
      if (!mounted || gen != _codingGen) return;
      var reason = _reasonOf(ent);
      if (pinned == null &&
          (reason == 'not_configured' ||
              reason == 'no_plan' ||
              reason == 'not_authenticated')) {
        final altFamily = family == 'bigmodel' ? 'zai' : 'bigmodel';
        final alt = await _callEnt(bridge, altFamily, 'individual-coding-plan');
        if (!mounted || gen != _codingGen) return;
        if (alt != null && _reasonOf(alt).isEmpty) {
          ent = alt;
          family = altFamily;
          reason = '';
        }
      }
      final cp = reason.isEmpty
          ? await _callToday(bridge, family, 'individual-coding-plan', tz)
          : null;
      if (!mounted || gen != _codingGen) return;
      if (accountId != null) {
        final snap = _buildCodingCacheSnapshot(
          accountId: accountId,
          family: family,
          ent: ent,
          todayCp: cp,
        );
        if (snap != null) {
          unawaited(
            app.uiPrefs.saveOfficialQuotaCache(
              snap,
              expectedEpoch: cacheEpoch,
            ),
          );
        }
      }
      setState(() {
        _codingFamily = family;
        _codingEnt = ent;
        _codingToday = cp;
        _codingCached = null;
        _codingLoading = false;
        _codingError = null;
      });
    } catch (_) {
      final cached = accountId != null
          ? app.uiPrefs.officialQuotaFor(accountId)
          : null;
      if (!mounted || gen != _codingGen) return;
      setState(() {
        _codingLoading = false;
        _codingCached = cached;
        _codingError = cached == null ? '读取官方订阅额度失败，可点右上角重试' : null;
      });
    }
  }

  Future<void> _loadStart(
    AppState app,
    int gen,
    UsageQuickLayoutPrefs layout, {
    String? accountId,
    StoredAccount? account,
    bool force = false,
  }) async {
    final bridge =
        app.bridge ??
        (accountId != null ? app.onlineBridgeForAccount(accountId) : null);
    if (bridge == null) {
      // 离线兜底：桌面离线时，直接用手机已存 zcodejwttoken 查官方 Start Plan 余额，
      // 夜间 3 亿 GLM-5.3-Flash 等福利包离线照常实时可见。
      if (accountId != null && accountId.trim().isNotEmpty) {
        try {
          final jwt = await app.accountStore.readJwtFor(accountId);
          if (!mounted || gen != _startGen) return;
          if (jwt != null && jwt.trim().isNotEmpty) {
            final directEnt = await widget.startPlanClient.fetch(
              accountId: accountId,
              jwt: jwt,
              force: force,
            );
            if (!mounted || gen != _startGen) return;
            setState(() {
              _startLoading = false;
              _startEnt = directEnt;
              _startError = null;
              _startDirect = true;
            });
            return;
          }
        } catch (_) {
          // 读取凭据或直连失败时回落默认离线文案。
        }
      }
      if (!mounted || gen != _startGen) return;
      setState(() {
        _startLoading = false;
        _startEnt = null;
        _startDirect = false;
        _startError = '桌面离线，暂无法读取官方订阅额度';
      });
      return;
    }

    final pinned =
        _manualStartFamily ??
        (layout.startScope == 'auto' ? null : layout.startScope);
    var family = pinned ?? _detectDefaultFamily(app, account: account);

    try {
      var ent = await _callEnt(bridge, family, 'start-plan');
      if (!mounted || gen != _startGen) return;
      final reason = _reasonOf(ent);
      if (pinned == null &&
          (reason == 'not_configured' ||
              reason == 'no_plan' ||
              reason == 'not_authenticated')) {
        final altFamily = family == 'bigmodel' ? 'zai' : 'bigmodel';
        final alt = await _callEnt(bridge, altFamily, 'start-plan');
        if (!mounted || gen != _startGen) return;
        if (alt != null && _reasonOf(alt).isEmpty) {
          ent = alt;
          family = altFamily;
        }
      }
      if (!mounted || gen != _startGen) return;
      setState(() {
        _startFamily = family;
        _startEnt = ent;
        _startDirect = false;
        _startLoading = false;
        _startError = null;
      });
    } catch (_) {
      if (!mounted || gen != _startGen) return;
      setState(() {
        _startLoading = false;
        _startDirect = false;
        _startError = '读取官方订阅额度失败，可点右上角重试';
      });
    }
  }

  Future<void> _loadAccountCodingSlot(
    AppState app,
    StoredAccount account,
    int gen,
    UsageQuickLayoutPrefs layout,
  ) async {
    final bridge = app.onlineBridgeForAccount(account.id);
    final isActive = account.id == app.activeAccountId;
    if (bridge == null) {
      final cached = app.uiPrefs.officialQuotaFor(account.id);
      if (!mounted || gen != _multiCodingGen[account.id]) return;
      setState(() {
        _multiCoding[account.id] = _AccountCodingSlot(
          loading: false,
          cached: cached,
          family: cached?.family ?? _detectDefaultFamily(app, account: account),
          isOnline: false,
          quietOffline: !isActive && cached == null,
          error: cached == null
              ? (isActive
                    ? '桌面离线，暂无法读取官方订阅额度'
                    : '未连接该账号电脑，连上后自动缓存')
              : null,
        );
      });
      return;
    }

    final pinned =
        _manualMultiCodingFamily[account.id] ??
        (layout.codingScope == 'auto' ? null : layout.codingScope);
    var family = pinned ?? _detectDefaultFamily(app, account: account);
    final cacheEpoch = app.uiPrefs.officialQuotaCacheEpoch(account.id);

    try {
      final tz = await readDeviceTimeZone();
      if (!mounted || gen != _multiCodingGen[account.id]) return;
      var ent = await _callEnt(bridge, family, 'individual-coding-plan');
      if (!mounted || gen != _multiCodingGen[account.id]) return;
      var reason = _reasonOf(ent);
      if (pinned == null &&
          (reason == 'not_configured' ||
              reason == 'no_plan' ||
              reason == 'not_authenticated')) {
        final altFamily = family == 'bigmodel' ? 'zai' : 'bigmodel';
        final alt = await _callEnt(bridge, altFamily, 'individual-coding-plan');
        if (!mounted || gen != _multiCodingGen[account.id]) return;
        if (alt != null && _reasonOf(alt).isEmpty) {
          ent = alt;
          family = altFamily;
          reason = '';
        }
      }
      final cp = reason.isEmpty
          ? await _callToday(bridge, family, 'individual-coding-plan', tz)
          : null;
      if (!mounted || gen != _multiCodingGen[account.id]) return;
      final snap = _buildCodingCacheSnapshot(
        accountId: account.id,
        family: family,
        ent: ent,
        todayCp: cp,
      );
      if (snap != null) {
        unawaited(
          app.uiPrefs.saveOfficialQuotaCache(snap, expectedEpoch: cacheEpoch),
        );
      }
      setState(() {
        _multiCoding[account.id] = _AccountCodingSlot(
          loading: false,
          ent: ent,
          todayCp: cp,
          family: family,
          isOnline: true,
        );
      });
    } catch (_) {
      final cached = app.uiPrefs.officialQuotaFor(account.id);
      if (!mounted || gen != _multiCodingGen[account.id]) return;
      setState(() {
        _multiCoding[account.id] = _AccountCodingSlot(
          loading: false,
          cached: cached,
          family: family,
          isOnline: true,
          error: cached == null ? '读取官方订阅额度失败，可点右上角重试' : null,
        );
      });
    }
  }

  Future<void> _loadAccountStartSlot(
    AppState app,
    StoredAccount account,
    int gen,
    UsageQuickLayoutPrefs layout, {
    required bool force,
  }) async {
    final bridge = app.onlineBridgeForAccount(account.id);
    if (bridge != null) {
      final pinned =
          _manualMultiStartFamily[account.id] ??
          (layout.startScope == 'auto' ? null : layout.startScope);
      var family = pinned ?? _detectDefaultFamily(app, account: account);
      try {
        var ent = await _callEnt(bridge, family, 'start-plan');
        if (!mounted || gen != _multiStartGen[account.id]) return;
        final reason = _reasonOf(ent);
        if (pinned == null &&
            (reason == 'not_configured' ||
                reason == 'no_plan' ||
                reason == 'not_authenticated')) {
          final altFamily = family == 'bigmodel' ? 'zai' : 'bigmodel';
          final alt = await _callEnt(bridge, altFamily, 'start-plan');
          if (!mounted || gen != _multiStartGen[account.id]) return;
          if (alt != null && _reasonOf(alt).isEmpty) {
            ent = alt;
            family = altFamily;
          }
        }
        if (!mounted || gen != _multiStartGen[account.id]) return;
        setState(() {
          _multiStart[account.id] = _AccountStartSlot(
            loading: false,
            ent: ent,
            family: family,
            isDirect: false,
          );
        });
        return;
      } catch (_) {
        // 桥接异常时自动退回手机 JWT 直连，尽力不丢福利包。
      }
    }

    // 离线账号或非活跃账号：凭 AccountStore 已存 zcodejwttoken 手机直连官方 Start Plan。
    try {
      final jwt = await app.accountStore.readJwtFor(account.id);
      if (!mounted || gen != _multiStartGen[account.id]) return;
      if (jwt != null && jwt.trim().isNotEmpty) {
        final directEnt = await widget.startPlanClient.fetch(
          accountId: account.id,
          jwt: jwt,
          force: force,
        );
        if (!mounted || gen != _multiStartGen[account.id]) return;
        setState(() {
          _multiStart[account.id] = _AccountStartSlot(
            loading: false,
            ent: directEnt,
            family: _detectDefaultFamily(app, account: account),
            isDirect: true,
          );
        });
        return;
      }
    } catch (_) {
      // 忽略直连读错，交由下方静默隐身或兜底。
    }
    if (!mounted || gen != _multiStartGen[account.id]) return;
    setState(() {
      _multiStart[account.id] = _AccountStartSlot(
        loading: false,
        ent: const {'unavailableReason': 'no_plan'},
        family: _detectDefaultFamily(app, account: account),
        isDirect: true,
      );
    });
  }

  Future<void> _loadExternal(
    Map<String, ExternalQuotaProviderConfig> configs,
    int gen, {
    required bool force,
  }) async {
    if (configs.isEmpty) {
      if (!mounted || gen != _externalGen) return;
      setState(() {
        _externalLoading = false;
        _externalSnapshots = const [];
      });
      return;
    }
    try {
      final results = await widget.externalClient.fetchAll(
        configs,
        force: force,
      );
      if (!mounted || gen != _externalGen) return;
      setState(() {
        _externalSnapshots = results;
      });
    } finally {
      if (mounted && gen == _externalGen) {
        setState(() => _externalLoading = false);
      }
    }
  }

  void _openConfig() {
    if (_editingConfig) return;
    setState(() => _editingConfig = true);
  }

  void _closeConfig(bool changed) {
    if (!mounted) return;
    setState(() {
      _editingConfig = false;
      _configSaving = false;
      if (changed) {
        _manualCodingFamily = null;
        _manualStartFamily = null;
        _manualMultiCodingFamily.clear();
        _manualMultiStartFamily.clear();
      }
    });
    if (changed) {
      widget.externalClient.clearCache();
      widget.startPlanClient.clearCache();
      unawaited(_loadAll(force: true));
    }
  }

  String _formatUpdatedClock(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  /// 紧凑网格里的重置时间：同日保留 HH:mm（如 22:52），跨日取 MM-DD（如 11-27），
  /// 与电脑端速览一致，避免手机两列网格中时间被省略号截断。
  String _compactResetLabel(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final spaceIdx = s.indexOf(' ');
    if (spaceIdx > 0 && s.contains('-')) {
      return s.substring(0, spaceIdx);
    }
    return s;
  }

  Widget _statusDot(Color color) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _quotaCell(
    BuildContext context, {
    required String label,
    required double remainingPercent,
    required Color accentColor,
    String resetText = '',
  }) {
    final c = context.colors;
    final pct = remainingPercent.clamp(0.0, 100.0);
    final barColor = pct <= 10
        ? c.destructive
        : pct <= 25
        ? c.warning
        : accentColor;
    final pctLabel = pct == pct.roundToDouble()
        ? '${pct.round()}%'
        : '${pct.toStringAsFixed(1)}%';
    final compactReset = _compactResetLabel(resetText);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: AppType.uiXs, color: c.foregroundSubtle),
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 4,
          runSpacing: 1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 专用模式「剩余 42%」→ EN「42% left」，避开 custom_l10n 中
            // '剩余'→'free ' 的上下文专用词。
            Text(
              '剩余 $pctLabel',
              style: TextStyle(
                fontSize: AppType.uiSm,
                fontWeight: FontWeight.w700,
                color: pct <= 25 ? barColor : c.foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (compactReset.isNotEmpty)
              Text(
                '· $compactReset',
                translate: false,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: c.foregroundSubtlest,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: pct / 100.0,
            minHeight: 4,
            backgroundColor: c.surfaceHover,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
      ],
    );
  }

  /// 外部窗口按语义分配周期色：短窗蓝、周/7天绿、月度紫，与电脑端一致。
  Color _externalWindowColor(BuildContext context, int index, String label) {
    final series = context.charts.series;
    final l = label.toLowerCase();
    if (l.contains('5') || l.contains('rolling') || l.contains('小时')) {
      return series[0]; // 蓝
    }
    if (l.contains('7') || l.contains('周') || l.contains('week')) {
      return series[1]; // 绿
    }
    if (l.contains('月') || l.contains('month')) {
      return series[2]; // 紫
    }
    return series[index % series.length];
  }

  /// 两列紧凑网格：将 N 个配额窗口两两成行，奇数末项半宽左对齐。
  Widget _quotaGrid(
    BuildContext context,
    List<
      ({
        String label,
        double remainingPercent,
        Color accentColor,
        String resetText,
      })
    >
    items,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final left = items[i];
      final right = i + 1 < items.length ? items[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 6 : 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _quotaCell(
                  context,
                  label: left.label,
                  remainingPercent: left.remainingPercent,
                  accentColor: left.accentColor,
                  resetText: left.resetText,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: right != null
                    ? _quotaCell(
                        context,
                        label: right.label,
                        remainingPercent: right.remainingPercent,
                        accentColor: right.accentColor,
                        resetText: right.resetText,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _buildFamilyPill(
    BuildContext context, {
    required ValueKey<String> buttonKey,
    required String prefixKey,
    required String currentFamily,
    required ValueChanged<String> onSelected,
  }) {
    final c = context.colors;
    return PopupMenuButton<String>(
      key: buttonKey,
      tooltip: tr('切换官方套餐来源'),
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final pair in const [
          ('bigmodel', 'BigModel'),
          ('zai', 'Z.AI'),
        ])
          PopupMenuItem<String>(
            key: ValueKey('$prefixKey-${pair.$1}'),
            value: pair.$1,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    pair.$2,
                    translate: false,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: currentFamily == pair.$1
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (currentFamily == pair.$1) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 16, color: c.brandAccent),
                ],
              ],
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
        child: Align(
          alignment: Alignment.centerRight,
          widthFactor: 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: c.brandAccent.withValues(alpha: AppAlpha.faint),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  currentFamily == 'zai' ? 'Z.AI' : 'BigModel',
                  translate: false,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: c.brandAccentBright,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: c.brandAccentBright,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMutedBadge(
    BuildContext context,
    String text, {
    bool translate = true,
  }) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: isDark ? c.borderHover : c.border),
      ),
      child: Text(
        text,
        translate: translate,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppType.uiXs,
          color: isDark ? c.foreground : c.foregroundSubtle,
        ),
      ),
    );
  }

  Widget _buildOfficialQuotaSection(
    BuildContext context, {
    required ValueKey<String> cardKey,
    required ValueKey<String> scopeKey,
    required String scopePrefix,
    required String defaultTitle,
    required bool loading,
    required String? error,
    required Map<String, dynamic>? ent,
    required Map<String, dynamic>? todayCp,
    required String family,
    required ValueChanged<String> onSelectFamily,
    String? accountSuffix,
    CachedOfficialQuota? cached,
    bool isDirect = false,
    bool quietOffline = false,
  }) {
    final c = context.colors;
    final series = context.charts.series;
    final quota = ent?['quota'] is Map
        ? (ent!['quota'] as Map).cast<String, dynamic>()
        : null;
    final limits = quota?['limits'] is List ? quota!['limits'] as List : null;
    final mcpQuota = ent?['mcpQuota'] is Map
        ? (ent!['mcpQuota'] as Map).cast<String, dynamic>()
        : null;
    final mcpAggregate = mcpQuota?['aggregate'] is Map
        ? (mcpQuota!['aggregate'] as Map).cast<String, dynamic>()
        : null;
    final unavailableReason = _reasonOf(ent);
    final levelRaw = quota?['level'];
    final levelStr = levelRaw is String ? levelRaw : null;
    final subMap = ent?['subscription'] is Map
        ? (ent!['subscription'] as Map).cast<String, dynamic>()
        : null;
    final subDetails = subMap?['details'] is List
        ? subMap!['details'] as List
        : null;
    final firstDetail =
        (subDetails != null && subDetails.isNotEmpty && subDetails.first is Map)
        ? (subDetails.first as Map).cast<String, dynamic>()
        : null;
    final productNameRaw = firstDetail?['productName'];
    final productNameStr = productNameRaw is String ? productNameRaw : null;

    final fiveH = findQuotaLimit(limits, tokenKind: true, unit: 3, number: 5);
    final weekly = findQuotaLimit(limits, tokenKind: true, unit: 6);
    final toolLimit = findQuotaLimit(limits, tokenKind: false);
    final hasAnyLimit =
        fiveH != null ||
        weekly != null ||
        toolLimit != null ||
        mcpAggregate != null;
    final startWindows = !hasAnyLimit
        ? extractStartPlanWindows(ent)
        : const <({String label, double remainingPercent, String resetText})>[];

    final liveOk =
        !loading &&
        error == null &&
        ent != null &&
        unavailableReason.isEmpty &&
        (hasAnyLimit || startWindows.isNotEmpty);
    final usingCache = !loading && !liveOk && cached != null;

    final basePlanName = usingCache
        ? cached.planName
        : (formatPlanName(level: levelStr, productName: productNameStr) ??
              defaultTitle);
    final suffix = accountSuffix?.trim() ?? '';
    final planName = suffix.isEmpty ? basePlanName : '$basePlanName · $suffix';

    final summary = _extractTodaySummary(todayCp);
    final rawTotal = usingCache ? cached.todayTotalTokens : summary?['totalTokens'];
    final todayTotal = rawTotal is num ? rawTotal : null;
    final rawPeak = usingCache
        ? cached.todayPeakTokens
        : (summary?['peakDailyTokens'] ?? summary?['peakTokens']);
    final todayPeak = rawPeak is num ? rawPeak : null;

    final isUnavailableError =
        unavailableReason == 'not_authenticated' ||
        unavailableReason == 'unavailable';
    final dotColor = loading || usingCache || quietOffline
        ? c.foregroundSubtlest
        : liveOk
        ? c.success
        : ((error != null || isUnavailableError)
              ? c.warning
              : c.foregroundSubtlest);

    final gridItems = usingCache
        ? <
            ({
              String label,
              double remainingPercent,
              Color accentColor,
              String resetText,
            })
          >[
            for (final w in cached.windows)
              (
                label: w.label,
                remainingPercent: w.remainingPercent,
                accentColor: series[w.colorSlot % series.length],
                resetText: w.resetAtMs != null
                    ? formatResetTime(w.resetAtMs)
                    : '',
              ),
          ]
        : <
            ({
              String label,
              double remainingPercent,
              Color accentColor,
              String resetText,
            })
          >[
            if (fiveH != null)
              (
                label: '5 小时窗口',
                remainingPercent: quotaRemainingPercent(fiveH),
                accentColor: series[0],
                resetText: formatResetTime(fiveH['nextResetTime']),
              ),
            if (weekly != null)
              (
                label: '每周配额',
                remainingPercent: quotaRemainingPercent(weekly),
                accentColor: series[1],
                resetText: formatResetTime(weekly['nextResetTime']),
              ),
            if (toolLimit != null)
              (
                label: '每月工具调用',
                remainingPercent: quotaRemainingPercent(toolLimit),
                accentColor: series[2],
                resetText: formatResetTime(toolLimit['nextResetTime']),
              ),
            if (mcpAggregate != null)
              (
                label: 'MCP 额度',
                remainingPercent: quotaRemainingPercent(mcpAggregate),
                accentColor: series[5],
                resetText: formatResetTime(mcpAggregate['nextResetTime']),
              ),
            for (var i = 0; i < startWindows.length; i++)
              (
                label: startWindows[i].label,
                remainingPercent: startWindows[i].remainingPercent,
                accentColor: series[i % series.length],
                resetText: startWindows[i].resetText,
              ),
          ];

    return Container(
      key: cardKey,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusDot(dotColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  planName,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w600,
                    color: c.foreground,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (usingCache)
                Flexible(
                  flex: 0,
                  child: _buildMutedBadge(
                    context,
                    formatOfficialQuotaCacheAge(cached.cachedAt),
                    translate: false,
                  ),
                )
              else if (isDirect)
                _buildMutedBadge(context, '直连')
              else if (!quietOffline)
                _buildFamilyPill(
                  context,
                  buttonKey: scopeKey,
                  prefixKey: scopePrefix,
                  currentFamily: family,
                  onSelected: onSelectFamily,
                ),
            ],
          ),
          if (loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.brandAccent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '正在拉取官方额度…',
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: c.foregroundSubtle,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (usingCache || liveOk) ...[
            _quotaGrid(context, gridItems),
            if (todayTotal != null && todayTotal > 0) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  Text(
                    '${tr('今日累计')} ${tr(formatTokens(todayTotal))}',
                    translate: false,
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: c.foregroundSubtle,
                    ),
                  ),
                  if (todayPeak != null && todayPeak > 0)
                    Text(
                      '${tr('今日峰值')} ${tr(formatTokens(todayPeak))}',
                      translate: false,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: c.foregroundSubtle,
                      ),
                    ),
                ],
              ),
            ],
          ] else if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                error,
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  color: c.foregroundSubtle,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                unavailableReason == 'not_authenticated'
                    ? (isDirect
                          ? '账号登录凭据已失效，请重新登录'
                          : '桌面端未登录官方账号，无法读取套餐额度')
                    : unavailableReason == 'unavailable'
                    ? '官方额度服务暂时不可用，请稍后刷新'
                    : '当前账号暂无官方套餐额度数据',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  color: c.foregroundSubtle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExternalCard(
    BuildContext context,
    ExternalQuotaSnapshot snapshot,
  ) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: ValueKey('usage-quick-ext-${snapshot.entryId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusDot(snapshot.ok ? c.success : c.destructive),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  snapshot.displayTitle,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w600,
                    color: c.foreground,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: isDark ? c.borderHover : c.border,
                  ),
                ),
                child: Text(
                  '外部额度',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: isDark ? c.foreground : c.foregroundSubtle,
                  ),
                ),
              ),
            ],
          ),
          if (!snapshot.ok) ...[
            const SizedBox(height: 8),
            Text(
              snapshot.error ?? '查询失败',
              style: TextStyle(fontSize: AppType.uiSm, color: c.destructive),
            ),
            if (snapshot.hint != null && snapshot.hint!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                snapshot.hint!,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: c.foregroundSubtle,
                ),
              ),
            ],
          ] else ...[
            _quotaGrid(context, [
              for (var i = 0; i < snapshot.windows.length; i++)
                (
                  label: snapshot.windows[i].label,
                  remainingPercent: snapshot.windows[i].remainingPercent,
                  accentColor: _externalWindowColor(
                    context,
                    i,
                    snapshot.windows[i].label,
                  ),
                  resetText: snapshot.windows[i].resetLabel,
                ),
            ]),
            for (final note in snapshot.notes) ...[
              const SizedBox(height: 5),
              Text(
                note,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: c.foregroundSubtle,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  List<Widget> _buildOrderedCards(BuildContext context, AppState app) {
    final c = context.colors;
    if (_accountsLoading && !_accountsLoaded) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.brandAccent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在拉取官方额度…',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: c.foregroundSubtle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final layout = app.uiPrefs.usageQuickLayout;
    final extEntries = app.uiPrefs.externalQuotaEntries;
    final officialIds = _officialCardIdsFor(_accounts);
    final order = layout.resolvedOrder(
      extEntries,
      officialCardIds: officialIds,
    );
    final snapByEntryId = <String, ExternalQuotaSnapshot>{
      for (final s in _externalSnapshots) s.entryId: s,
    };
    final accountById = <String, StoredAccount>{
      for (final a in _accounts) a.id: a,
    };

    final singleAccountId =
        app.activeAccountId ?? (_accounts.isNotEmpty ? _accounts.first.id : null);
    bool isCardVisible(String cardId) {
      if (cardId.startsWith(kUsageCardExternalPrefix)) {
        return layout.isVisible(cardId);
      }
      return layout.isOfficialCardVisible(
        cardId,
        isMultiAccount: _isMultiAccount,
        singleAccountId: singleAccountId,
      );
    }

    final anyVisibleOfficial = officialIds.any(isCardVisible);
    final codingVisible = _isMultiAccount
        ? _accounts.any((a) => isCardVisible(usageCardOfficialCodingId(a.id)))
        : isCardVisible(kUsageCardOfficialCoding);
    final startExplicit =
        layout.startScope != 'auto' || _manualStartFamily != null;
    final startHasActive = _hasOfficialQuotaData(_startEnt);
    final anyVisibleExternal = extEntries.any(
      (e) => layout.isVisible(usageCardExternalId(e.id)),
    );

    final cards = <Widget>[];
    var externalSpinnerAdded = false;

    for (final cardId in order) {
      if (!isCardVisible(cardId)) continue;
      if (!_isMultiAccount && cardId == kUsageCardOfficialCoding) {
        cards.add(
          _buildOfficialQuotaSection(
            context,
            cardKey: const ValueKey('usage-quick-official-card'),
            scopeKey: const ValueKey('usage-quick-coding-scope'),
            scopePrefix: 'usage-scope-coding',
            defaultTitle: 'GLM Coding Plan',
            loading: _codingLoading,
            error: _codingError,
            ent: _codingEnt,
            todayCp: _codingToday,
            cached: _codingCached,
            family: _codingFamily,
            onSelectFamily: _selectCodingFamily,
          ),
        );
      } else if (!_isMultiAccount && cardId == kUsageCardOfficialStart) {
        final shouldShowStart =
            startHasActive ||
            startExplicit ||
            (!codingVisible && !anyVisibleExternal && !_startLoading);
        if (!shouldShowStart) continue;
        cards.add(
          _buildOfficialQuotaSection(
            context,
            cardKey: const ValueKey('usage-quick-start-card'),
            scopeKey: const ValueKey('usage-quick-start-scope'),
            scopePrefix: 'usage-scope-start',
            defaultTitle: 'Start Plan',
            loading: _startLoading,
            error: _startError,
            ent: _startEnt,
            todayCp: null,
            family: _startFamily,
            isDirect: _startDirect,
            onSelectFamily: _selectStartFamily,
          ),
        );
      } else if (_isMultiAccount &&
          cardId.startsWith(kUsageCardOfficialCodingPrefix)) {
        final accId = cardId.substring(kUsageCardOfficialCodingPrefix.length);
        final acc = accountById[accId];
        if (acc == null) continue;
        final slot = _multiCoding[accId] ?? const _AccountCodingSlot();
        cards.add(
          _buildOfficialQuotaSection(
            context,
            cardKey: ValueKey('usage-quick-official-coding-$accId'),
            scopeKey: ValueKey('usage-quick-coding-scope-$accId'),
            scopePrefix: 'usage-scope-coding-$accId',
            defaultTitle: 'GLM Coding Plan',
            accountSuffix: acc.displayName,
            loading: slot.loading,
            error: slot.error,
            ent: slot.ent,
            todayCp: slot.todayCp,
            cached: slot.cached,
            family: slot.family,
            quietOffline: slot.quietOffline,
            onSelectFamily: (f) => _selectMultiCodingFamily(acc, f),
          ),
        );
      } else if (_isMultiAccount &&
          cardId.startsWith(kUsageCardOfficialStartPrefix)) {
        final accId = cardId.substring(kUsageCardOfficialStartPrefix.length);
        final acc = accountById[accId];
        if (acc == null) continue;
        final slot = _multiStart[accId] ?? const _AccountStartSlot();
        final hasActive = _hasOfficialQuotaData(slot.ent);
        final explicit =
            layout.startScope != 'auto' ||
            _manualMultiStartFamily.containsKey(accId);
        // 多账号 Start Plan 同样遵循「有福利包自动显示，无则静默隐身」原则。
        if (!hasActive && !explicit) continue;
        cards.add(
          _buildOfficialQuotaSection(
            context,
            cardKey: ValueKey('usage-quick-official-start-$accId'),
            scopeKey: ValueKey('usage-quick-start-scope-$accId'),
            scopePrefix: 'usage-scope-start-$accId',
            defaultTitle: 'Start Plan',
            accountSuffix: acc.displayName,
            loading: slot.loading,
            error: null,
            ent: slot.ent,
            todayCp: null,
            family: slot.family,
            isDirect: slot.isDirect,
            onSelectFamily: (f) => _selectMultiStartFamily(acc, f),
          ),
        );
      } else if (cardId.startsWith(kUsageCardExternalPrefix)) {
        final entryId = cardId.substring(kUsageCardExternalPrefix.length);
        if (_externalLoading) {
          if (!externalSpinnerAdded) {
            externalSpinnerAdded = true;
            cards.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.brandAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '正在查询外部额度…',
                        style: TextStyle(
                          fontSize: AppType.uiSm,
                          color: c.foregroundSubtle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          continue;
        }
        final snap = snapByEntryId[entryId];
        if (snap != null) {
          cards.add(_buildExternalCard(context, snap));
        }
      }
    }

    if (cards.isEmpty) {
      if (!anyVisibleOfficial && !anyVisibleExternal) {
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              '已隐藏全部额度卡片，可点右上角 + 自定义',
              style: TextStyle(
                fontSize: AppType.uiSm,
                color: c.foregroundSubtle,
              ),
            ),
          ),
        ];
      }
      if (_startLoading || _multiStart.values.any((s) => s.loading)) {
        return [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.brandAccent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '正在拉取官方额度…',
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      color: c.foregroundSubtle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ];
      }
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(
            '当前未启用官方套餐，可点右上角 + 自定义显示',
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: c.foregroundSubtle,
            ),
          ),
        ),
      ];
    }

    final out = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      if (i > 0) {
        out.add(Divider(height: 14, color: c.borderFaint));
      }
      out.add(cards[i]);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (_editingConfig) {
      // 单层弹层内切换自定义页：避免双层 BottomSheet 叠出双拖拽条，
      // 保存中阻断系统返回键防止卸载中途丢失刷新回调。
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _editingConfig && !_configSaving) _closeConfig(false);
        },
        child: _UsageQuickCustomizeSheet(
          accounts: _accounts,
          onDone: _closeConfig,
          onSavingChanged: (saving) {
            if (mounted && _configSaving != saving) {
              setState(() => _configSaving = saving);
            }
          },
        ),
      );
    }
    final c = context.colors;
    final app = AppStateScope.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '用量速览',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiLg,
                            fontWeight: FontWeight.w600,
                            color: c.foreground,
                          ),
                        ),
                        if (_updatedAt != null)
                          Text(
                            '更新于 ${_formatUpdatedClock(_updatedAt!)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: c.foregroundSubtlest,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('usage-quick-refresh'),
                    tooltip: tr('刷新额度'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _anyLoading ? null : () => _loadAll(force: true),
                  ),
                  IconButton(
                    key: const ValueKey('usage-quick-config'),
                    tooltip: tr('自定义与添加额度'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 22),
                    onPressed: _accountsLoaded ? _openConfig : null,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.borderFaint),
            Flexible(
              child: ListenableBuilder(
                listenable: app.uiPrefs,
                builder: (context, _) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _buildOrderedCards(context, app),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('usage-quick-open-full'),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.brand,
                    foregroundColor: c.onBrand,
                    minimumSize: const Size(double.infinity, 42),
                  ),
                  onPressed: () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.push(
                      MaterialPageRoute(builder: (_) => const UsagePage()),
                    );
                  },
                  child: const Text('查看完整用量统计'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「自定义用量速览」单弹层页：
/// 1) 展示顺序拖动与各卡片开关（官方 GLM Coding / Start Plan + 外部账号）；
/// 2) 外部订阅账号按需添加与编辑，附可折叠「安全说明 · 开源可审」与实时直连 URL。
class _UsageQuickCustomizeSheet extends StatefulWidget {
  const _UsageQuickCustomizeSheet({
    this.accounts,
    this.onDone,
    this.onSavingChanged,
  });

  /// 传入 null（例如独立调用 `showExternalQuotaConfigSheet`）时内部自动异步加载账号列表，
  /// 避免在账号尚未就绪时误按单账号保存从而抹除多账号排版偏好。
  final List<StoredAccount>? accounts;
  final void Function(bool changed)? onDone;
  final ValueChanged<bool>? onSavingChanged;

  @override
  State<_UsageQuickCustomizeSheet> createState() =>
      _UsageQuickCustomizeSheetState();
}

class _DraftExternalEntry {
  _DraftExternalEntry({
    required this.id,
    required this.providerId,
    String label = '',
    String apiKey = '',
    String baseUrl = '',
  }) : labelCtrl = TextEditingController(text: label),
       keyCtrl = TextEditingController(text: apiKey),
       baseCtrl = TextEditingController(text: baseUrl);

  String id;
  String providerId;
  final TextEditingController labelCtrl;
  final TextEditingController keyCtrl;
  final TextEditingController baseCtrl;
  bool obscure = true;

  void dispose() {
    labelCtrl.dispose();
    keyCtrl.dispose();
    baseCtrl.dispose();
  }
}

class _UsageQuickCustomizeSheetState extends State<_UsageQuickCustomizeSheet> {
  final List<_DraftExternalEntry> _entries = [];
  final List<String> _order = [];
  final Set<String> _hidden = {};
  List<StoredAccount> _accounts = const [];
  bool _loadingAccounts = false;
  String _codingScope = 'auto';
  String _startScope = 'auto';

  int _draftSeq = 0;
  bool _saving = false;
  bool _initialized = false;
  bool _securityExpanded = false;
  bool _copiedSource = false;
  String? _errorText;

  bool get _isMultiAccount => _accounts.length > 1;

  List<String> get _officialCardIds {
    if (!_isMultiAccount) {
      return const [kUsageCardOfficialCoding, kUsageCardOfficialStart];
    }
    return [
      for (final a in _accounts) ...[
        usageCardOfficialCodingId(a.id),
        usageCardOfficialStartId(a.id),
      ],
    ];
  }

  StoredAccount? _findAccount(String accountId) {
    for (final a in _accounts) {
      if (a.id == accountId) return a;
    }
    return null;
  }

  void _applyLayoutWithAccounts(
    UsageQuickLayoutPrefs layout,
    List<ExternalQuotaProviderConfig> existing,
    List<StoredAccount> accounts,
  ) {
    _accounts = accounts;
    _order
      ..clear()
      ..addAll(layout.resolvedOrder(existing, officialCardIds: _officialCardIds));
    _hidden
      ..clear()
      ..addAll(layout.hidden);
    // 1 ↔ 多账号平滑承接：统一经 UsageQuickLayoutPrefs.isOfficialCardVisible
    // 继承单/多账号边界的官方卡片隐藏态，确保自定义页开关与速览主视图完全一致。
    final singleAccountId = _accounts.length == 1 ? _accounts.first.id : null;
    for (final cardId in _officialCardIds) {
      if (!layout.isOfficialCardVisible(
        cardId,
        isMultiAccount: _isMultiAccount,
        singleAccountId: singleAccountId,
      )) {
        _hidden.add(cardId);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final app = AppStateScope.of(context);
    final prefs = app.uiPrefs;
    final existing = prefs.externalQuotaEntries;
    for (final cfg in existing) {
      _entries.add(
        _DraftExternalEntry(
          id: cfg.id,
          providerId: cfg.providerId,
          label: cfg.label,
          apiKey: cfg.apiKey,
          baseUrl: cfg.baseUrl,
        ),
      );
    }
    final layout = prefs.usageQuickLayout;
    _codingScope = layout.codingScope;
    _startScope = layout.startScope;
    if (widget.accounts != null) {
      _applyLayoutWithAccounts(layout, existing, widget.accounts!);
    } else {
      _loadingAccounts = true;
      _applyLayoutWithAccounts(layout, existing, const []);
      unawaited(() async {
        final loaded = await _loadOrderedAccountsFor(app);
        if (!mounted) return;
        setState(() {
          _loadingAccounts = false;
          _applyLayoutWithAccounts(
            app.uiPrefs.usageQuickLayout,
            [
              for (final e in _entries)
                ExternalQuotaProviderConfig(
                  id: e.id,
                  providerId: e.providerId,
                  apiKey: e.keyCtrl.text,
                  baseUrl: e.baseCtrl.text,
                  label: e.labelCtrl.text,
                ),
            ],
            loaded,
          );
        });
      }());
    }
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  String _nextUniqueDraftId() {
    final existingIds = {for (final e in _entries) e.id};
    var nextId = 'ext-${++_draftSeq}';
    while (existingIds.contains(nextId)) {
      nextId = 'ext-${++_draftSeq}';
    }
    return nextId;
  }

  _DraftExternalEntry? _findEntry(String entryId) {
    for (final e in _entries) {
      if (e.id == entryId) return e;
    }
    return null;
  }

  void _resetDefaults() {
    setState(() {
      _errorText = null;
      _hidden.clear();
      _codingScope = 'auto';
      _startScope = 'auto';
      _order
        ..clear()
        ..addAll(_officialCardIds)
        ..addAll([for (final e in _entries) usageCardExternalId(e.id)]);
    });
  }

  void _addEntry() {
    if (_entries.length >= kMaxExternalQuotaEntries) {
      setState(() => _errorText = '最多可添加 20 个外部额度查询');
      return;
    }
    final usedProviders = {for (final e in _entries) e.providerId};
    var defaultProvider = kExternalQuotaAdapters.first.id;
    for (final a in kExternalQuotaAdapters) {
      if (!usedProviders.contains(a.id)) {
        defaultProvider = a.id;
        break;
      }
    }
    final nextId = _nextUniqueDraftId();
    setState(() {
      _errorText = null;
      _entries.add(_DraftExternalEntry(id: nextId, providerId: defaultProvider));
      _order.add(usageCardExternalId(nextId));
    });
  }

  void _removeEntry(int index) {
    final removed = _entries[index];
    final cardId = usageCardExternalId(removed.id);
    setState(() {
      _entries.removeAt(index);
      _order.remove(cardId);
      _hidden.remove(cardId);
      _errorText = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Future<void> _copySourceUrl() async {
    await Clipboard.setData(const ClipboardData(text: kExternalQuotaSourceUrl));
    if (!mounted) return;
    setState(() => _copiedSource = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedSource = false);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final nav = Navigator.of(context);
    final prefs = AppStateScope.of(context).uiPrefs;

    final toSave = <ExternalQuotaProviderConfig>[];
    final savedCardIds = <String>{..._officialCardIds};

    for (final entry in _entries) {
      final adapter = externalQuotaAdapterById(entry.providerId);
      if (adapter == null) continue;
      final key = entry.keyCtrl.text.trim();
      final base = entry.baseCtrl.text.trim();
      final label = entry.labelCtrl.text.trim();
      final name = label.isEmpty
          ? adapter.displayName
          : '${adapter.displayName} · $label';
      if (key.isEmpty) {
        if (label.isNotEmpty || base.isNotEmpty) {
          setState(() {
            _errorText = '请填写「$name」的 API Key，或清空/删除该项';
          });
          return;
        }
        continue;
      }
      if (!isValidExternalApiKey(key)) {
        setState(() {
          _errorText = 'API Key 格式无效（含换行或非法字符）';
        });
        return;
      }
      if (base.isNotEmpty &&
          resolveExternalQuotaUri(adapter, customBaseUrl: base) == null) {
        setState(() {
          _errorText = '$name 接口地址必须为有效的 HTTPS 地址';
        });
        return;
      }
      toSave.add(
        ExternalQuotaProviderConfig(
          id: entry.id,
          providerId: entry.providerId,
          apiKey: key,
          baseUrl: base,
          label: label,
        ),
      );
      savedCardIds.add(usageCardExternalId(entry.id));
    }

    final cleanOrder = [
      for (final id in _order)
        if (savedCardIds.contains(id)) id,
    ];
    final cleanHidden = {
      for (final id in _hidden)
        if (savedCardIds.contains(id)) id,
    };
    final nextLayout = UsageQuickLayoutPrefs(
      order: cleanOrder.isEmpty ? _officialCardIds : cleanOrder,
      hidden: cleanHidden,
      codingScope: _codingScope,
      startScope: _startScope,
    );

    setState(() {
      _saving = true;
      _errorText = null;
    });
    widget.onSavingChanged?.call(true);
    try {
      final ok = await prefs.saveUsageQuickSettings(
        externalEntries: toSave,
        layout: nextLayout,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _errorText = '加密存储写入失败，请重试';
        });
        return;
      }
      if (widget.onDone != null) {
        widget.onDone!(true);
      } else {
        nav.pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorText = '保存失败，请重试：$e';
        });
      }
    } finally {
      widget.onSavingChanged?.call(false);
      if (mounted) setState(() => _saving = false);
    }
  }

  String _scopeChipText(String scope) => switch (scope) {
    'bigmodel' => 'BigModel',
    'zai' => 'Z.AI',
    _ => tr('自动'),
  };

  Widget _buildScopeChip(
    BuildContext context, {
    required String cardId,
    required String currentScope,
    required ValueChanged<String> onChanged,
  }) {
    final c = context.colors;
    return PopupMenuButton<String>(
      key: ValueKey('usage-diy-scope-$cardId'),
      tooltip: tr('切换官方套餐来源'),
      enabled: !_saving,
      padding: EdgeInsets.zero,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final pair in [
          ('auto', tr('自动')),
          ('bigmodel', 'BigModel'),
          ('zai', 'Z.AI'),
        ])
          PopupMenuItem<String>(
            key: ValueKey('usage-diy-scope-$cardId-${pair.$1}'),
            value: pair.$1,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    pair.$2,
                    translate: false,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: currentScope == pair.$1
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (currentScope == pair.$1) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check, size: 16, color: c.brandAccent),
                ],
              ],
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
        child: Align(
          alignment: Alignment.center,
          widthFactor: 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.surfaceHover,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: c.borderFaint),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _scopeChipText(currentScope),
                  translate: false,
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: c.foregroundSubtle,
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 13,
                  color: c.foregroundSubtle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiyRow(BuildContext context, int index, String cardId) {
    final c = context.colors;
    final visible = !_hidden.contains(cardId);
    final bool isSingleCoding = cardId == kUsageCardOfficialCoding;
    final bool isSingleStart = cardId == kUsageCardOfficialStart;
    final bool isMultiCoding = cardId.startsWith(kUsageCardOfficialCodingPrefix);
    final bool isMultiStart = cardId.startsWith(kUsageCardOfficialStartPrefix);
    final entry = cardId.startsWith(kUsageCardExternalPrefix)
        ? _findEntry(cardId.substring(kUsageCardExternalPrefix.length))
        : null;

    String title;
    String? subtitle;
    bool showCodingScope = false;
    bool showStartScope = false;
    if (isSingleCoding) {
      title = 'GLM Coding Plan';
      showCodingScope = true;
    } else if (isSingleStart) {
      title = 'GLM Start Plan';
      subtitle = '有福利包时自动显示';
      showStartScope = true;
    } else if (isMultiCoding) {
      final accId = cardId.substring(kUsageCardOfficialCodingPrefix.length);
      final acc = _findAccount(accId);
      if (acc == null) {
        return SizedBox.shrink(key: ValueKey('usage-diy-row-$cardId'));
      }
      title = 'GLM Coding Plan · ${acc.displayName}';
    } else if (isMultiStart) {
      final accId = cardId.substring(kUsageCardOfficialStartPrefix.length);
      final acc = _findAccount(accId);
      if (acc == null) {
        return SizedBox.shrink(key: ValueKey('usage-diy-row-$cardId'));
      }
      title = 'GLM Start Plan · ${acc.displayName}';
      subtitle = '有福利包时自动显示';
    } else if (entry != null) {
      final adapter =
          externalQuotaAdapterById(entry.providerId) ??
          kExternalQuotaAdapters.first;
      final label = entry.labelCtrl.text.trim();
      title = label.isEmpty
          ? adapter.displayName
          : '${adapter.displayName} · $label';
    } else {
      return SizedBox.shrink(key: ValueKey('usage-diy-row-$cardId'));
    }

    return Container(
      key: ValueKey('usage-diy-row-$cardId'),
      decoration: BoxDecoration(
        color: c.surface,
        border: index > 0
            ? Border(top: BorderSide(color: c.borderFaint))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(4, 2, 6, 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            enabled: !_saving,
            child: SizedBox(
              width: 28,
              height: 36,
              child: Icon(
                Icons.drag_handle,
                size: 16,
                color: c.foregroundSubtlest,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    fontWeight: FontWeight.w500,
                    color: visible ? c.foreground : c.foregroundSubtlest,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      height: 1.15,
                      color: c.foregroundSubtlest,
                    ),
                  ),
              ],
            ),
          ),
          if (showCodingScope) ...[
            const SizedBox(width: 4),
            _buildScopeChip(
              context,
              cardId: cardId,
              currentScope: _codingScope,
              onChanged: (v) => setState(() => _codingScope = v),
            ),
          ] else if (showStartScope) ...[
            const SizedBox(width: 4),
            _buildScopeChip(
              context,
              cardId: cardId,
              currentScope: _startScope,
              onChanged: (v) => setState(() => _startScope = v),
            ),
          ],
          Transform.scale(
            scale: 0.78,
            alignment: Alignment.centerRight,
            child: Switch.adaptive(
              key: ValueKey('usage-diy-toggle-$cardId'),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              value: visible,
              onChanged: _saving
                  ? null
                  : (v) {
                      setState(() {
                        if (v) {
                          _hidden.remove(cardId);
                        } else {
                          _hidden.add(cardId);
                        }
                      });
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityCard(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const ValueKey('ext-quota-security-card'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.borderFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('ext-quota-security-toggle'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => setState(() => _securityExpanded = !_securityExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 15,
                    color: c.success,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '安全说明 · 直连官网，开源可审',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w500,
                        color: c.foreground,
                      ),
                    ),
                  ),
                  Icon(
                    _securityExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: c.foregroundSubtle,
                  ),
                ],
              ),
            ),
          ),
          if (_securityExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(height: 8, color: c.borderFaint),
                  Text(
                    '• 仅手机直连对应官网 HTTPS 接口（禁止重定向），不经中继服务器，也不记录日志。',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: c.foregroundSubtle,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '• API Key 加密存于系统钥匙串且关闭云备份；输入框已禁用键盘联想；建议优先使用可随时吊销的专用 Key。',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: c.foregroundSubtle,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '• 查询代码完全开源在 external_quota.dart，可自行或交给 AI 核对。',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: c.foregroundSubtle,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '• 查询方式与开源工具 cc-switch 的实现同类：直连各家官方额度接口，只读取额度数据。',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: c.foregroundSubtle,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(
                        key: const ValueKey('ext-quota-copy-source'),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          side: BorderSide(color: c.border),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 32),
                        ),
                        onPressed: _copySourceUrl,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _copiedSource ? Icons.check : Icons.code,
                              size: 14,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                _copiedSource ? '已复制源码链接' : '复制源码链接',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: AppType.uiXs),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExternalEditorCard(
    BuildContext context,
    int i,
    _DraftExternalEntry entry,
  ) {
    final c = context.colors;
    final adapter =
        externalQuotaAdapterById(entry.providerId) ??
        kExternalQuotaAdapters.first;
    final resolvedUri = resolveExternalQuotaUri(
      adapter,
      customBaseUrl: entry.baseCtrl.text.trim(),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.borderFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: ValueKey('ext-quota-provider-${entry.id}'),
                    value: adapter.id,
                    isExpanded: true,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                      color: c.foreground,
                    ),
                    items: [
                      for (final a in kExternalQuotaAdapters)
                        DropdownMenuItem<String>(
                          value: a.id,
                          child: Text(
                            a.displayName,
                            translate: false,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) {
                            if (v == null || v == entry.providerId) return;
                            setState(() {
                              if (entry.id == entry.providerId) {
                                final oldCardId = usageCardExternalId(entry.id);
                                final newId = _nextUniqueDraftId();
                                final newCardId = usageCardExternalId(newId);
                                final pos = _order.indexOf(oldCardId);
                                if (pos >= 0) _order[pos] = newCardId;
                                if (_hidden.remove(oldCardId)) {
                                  _hidden.add(newCardId);
                                }
                                entry.id = newId;
                              }
                              entry.providerId = v;
                              _errorText = null;
                            });
                          },
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('ext-quota-remove-${entry.id}'),
                tooltip: tr('移除该账号'),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: c.foregroundSubtle,
                ),
                onPressed: _saving ? null : () => _removeEntry(i),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            key: ValueKey('ext-quota-label-${entry.id}'),
            controller: entry.labelCtrl,
            autocorrect: false,
            onChanged: (_) => setState(() => _errorText = null),
            decoration: InputDecoration(
              labelText: tr('备注名（可选）'),
              hintText: tr('如 主号、备用'),
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: ValueKey('ext-quota-key-${entry.id}'),
            controller: entry.keyCtrl,
            obscureText: entry.obscure,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) {
              if (_errorText != null) setState(() => _errorText = null);
            },
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: tr('粘贴对应平台 API Key'),
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              suffixIcon: IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  entry.obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  entry.obscure = !entry.obscure;
                }),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: ValueKey('ext-quota-base-${entry.id}'),
            controller: entry.baseCtrl,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => setState(() => _errorText = null),
            decoration: InputDecoration(
              labelText: tr('接口地址（可选）'),
              hintText: adapter.defaultBaseUrl,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            key: ValueKey('ext-quota-live-url-${entry.id}'),
            resolvedUri != null
                ? '将直连：$resolvedUri（仅 GET，禁重定向）'
                : '接口地址无效（仅支持 HTTPS 地址）',
            style: TextStyle(
              fontSize: AppType.uiXs,
              color: resolvedUri != null ? c.foregroundSubtlest : c.destructive,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final screenH = MediaQuery.sizeOf(context).height;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final availableH = math.max(
      220.0,
      math.min(screenH * 0.90, screenH - bottomInset - 16),
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: availableH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.onDone != null ? 4 : 16,
                  0,
                  8,
                  2,
                ),
                child: Row(
                  children: [
                    if (widget.onDone != null)
                      IconButton(
                        key: const ValueKey('ext-quota-back'),
                        tooltip: tr('返回'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_back, size: 20),
                        onPressed: _saving ? null : () => widget.onDone!(false),
                      ),
                    Expanded(
                      child: Text(
                        '自定义用量速览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiBase,
                          fontWeight: FontWeight.w600,
                          color: c.foreground,
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 112),
                      child: TextButton(
                        key: const ValueKey('usage-quick-reset-default'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(44, 34),
                        ),
                        onPressed: (_saving || _loadingAccounts)
                            ? null
                            : _resetDefaults,
                        child: const Text(
                          '恢复默认',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: AppType.uiXs),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_errorText != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  child: Text(
                    _errorText!,
                    key: const ValueKey('ext-quota-error'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      color: c.destructive,
                    ),
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '显示与顺序',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              fontWeight: FontWeight.w600,
                              color: c.foregroundSubtle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '拖动左侧手柄调整顺序',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: c.foregroundSubtlest,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_isMultiAccount) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(color: c.borderFaint),
                        ),
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '官方套餐来源',
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: c.foregroundSubtle,
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Coding',
                                  translate: false,
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: c.foregroundSubtlest,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                _buildScopeChip(
                                  context,
                                  cardId: kUsageCardOfficialCoding,
                                  currentScope: _codingScope,
                                  onChanged: (v) =>
                                      setState(() => _codingScope = v),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Start',
                                  translate: false,
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: c.foregroundSubtlest,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                _buildScopeChip(
                                  context,
                                  cardId: kUsageCardOfficialStart,
                                  currentScope: _startScope,
                                  onChanged: (v) =>
                                      setState(() => _startScope = v),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: Container(
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(color: c.borderFaint),
                        ),
                        child: ReorderableListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          itemCount: _order.length,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final moved = _order.removeAt(oldIndex);
                              _order.insert(newIndex, moved);
                            });
                          },
                          itemBuilder: (ctx, idx) =>
                              _buildDiyRow(ctx, idx, _order[idx]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '外部额度查询（可选）',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontWeight: FontWeight.w600,
                        color: c.foregroundSubtle,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '仅查剩余额度，订阅与模型配置请在桌面端完成',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: c.foregroundSubtlest,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _buildSecurityCard(context),
                    for (var i = 0; i < _entries.length; i++)
                      _buildExternalEditorCard(context, i, _entries[i]),
                    OutlinedButton(
                      key: const ValueKey('ext-quota-add-entry'),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        side: BorderSide(color: c.border),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        minimumSize: const Size(double.infinity, 38),
                      ),
                      onPressed: _saving ? null : _addEntry,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, size: 17),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '添加外部额度查询',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: AppType.uiSm),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('ext-quota-save'),
                    onPressed: (_saving || _loadingAccounts) ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.brand,
                      foregroundColor: c.onBrand,
                      minimumSize: const Size(double.infinity, 42),
                    ),
                    child: const Text('保存'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
