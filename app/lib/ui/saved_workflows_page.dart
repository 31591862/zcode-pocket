// 已保存工作流中枢（一键启动已保存工作流，对齐官方 saved-workflows/
// useSavedWorkflowLauncher.ts + savedWorkflowArgsForm.ts）。
//
// 协议依据（参考源码快照）：
// - listSavedWorkflows({workspacePath, workspaceIdentity?, scope})
//   -> {workflows: ZCodeSavedWorkflowEntry[], invalid: [], dir?: string}
// - 启动编排：createSession({workspaceId}) 建空会话 -> startSavedWorkflow
//   ({name, scope, args?}) -> accepted 跳会话；被拒/抛错立刻 deleteSession
//   回收空会话（官方不变式 2「失败在会话存在之前」）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide Text;

import '../core/l10n.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/channel_client.dart' show ChannelRpcError;
import 'app_widgets.dart' show AppLoading;
import 'conversation_page.dart';

/// 单个实参声明（官方 ZCodeSavedWorkflowArgSpec）。
class SavedWorkflowArgSpec {
  const SavedWorkflowArgSpec({
    required this.name,
    required this.type,
    this.description,
    this.required = false,
    this.hasDefault = false,
    this.defaultValue,
  });

  final String name;

  /// `'string' | 'number' | 'boolean' | 'json'`（未知类型回落 `'string'`）。
  final String type;
  final String? description;
  final bool required;
  final bool hasDefault;
  final Object? defaultValue;

  /// 默认值转编辑器初始文本（官方 formatSavedWorkflowArgValue 同构）。
  String initialEditorText() {
    if (!hasDefault || defaultValue == null) {
      return type == 'boolean' ? 'false' : '';
    }
    switch (type) {
      case 'boolean':
        return defaultValue == true ? 'true' : 'false';
      case 'number':
        return '$defaultValue';
      case 'json':
        return defaultValue is String
            ? jsonEncode(defaultValue)
            : const JsonEncoder.withIndent('  ').convert(defaultValue);
      default:
        return defaultValue is String
            ? defaultValue as String
            : jsonEncode(defaultValue);
    }
  }
}

/// 单条已保存工作流定义（官方 ZCodeSavedWorkflowEntry）。
class SavedWorkflowEntry {
  const SavedWorkflowEntry({
    required this.name,
    required this.description,
    required this.scope,
    required this.path,
    this.whenToUse,
    this.args = const [],
  });

  final String name;
  final String description;
  final String? whenToUse;

  /// `'project'` 或 `'global'`。
  final String scope;
  final String path;
  final List<SavedWorkflowArgSpec> args;
}

/// 列表解析结果。
class SavedWorkflowListData {
  const SavedWorkflowListData({
    this.entries = const [],
    this.invalidCount = 0,
    this.unsupported = false,
  });

  final List<SavedWorkflowEntry> entries;
  final int invalidCount;
  final bool unsupported;
}

/// 解析官方 listSavedWorkflows 返回载荷。纯函数供单测。
SavedWorkflowListData parseSavedWorkflowList(
  dynamic raw, {
  required String fallbackScope,
}) {
  if (raw is! Map) return const SavedWorkflowListData();
  final workflows = raw['workflows'];
  final invalid = raw['invalid'];
  final entries = <SavedWorkflowEntry>[];
  if (workflows is List) {
    for (final item in workflows.whereType<Map>()) {
      final name = '${item['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final desc = '${item['description'] ?? ''}'.trim();
      final whenToUse = '${item['whenToUse'] ?? ''}'.trim();
      final rawScope = '${item['scope'] ?? ''}'.trim();
      final scope =
          (rawScope == 'project' || rawScope == 'global')
          ? rawScope
          : fallbackScope;
      final path = '${item['path'] ?? ''}'.trim();
      final args = <SavedWorkflowArgSpec>[];
      final rawArgs = item['args'];
      if (rawArgs is Map) {
        for (final entry in rawArgs.entries) {
          final argName = '${entry.key}'.trim();
          final spec = entry.value;
          if (argName.isEmpty || spec is! Map) continue;
          final rawType = '${spec['type'] ?? 'string'}'.trim();
          final type =
              const {'string', 'number', 'boolean', 'json'}.contains(rawType)
              ? rawType
              : 'string';
          final argDesc = '${spec['description'] ?? ''}'.trim();
          final hasDefault = spec.containsKey('default');
          args.add(
            SavedWorkflowArgSpec(
              name: argName,
              type: type,
              description: argDesc.isEmpty ? null : argDesc,
              required: spec['required'] == true,
              hasDefault: hasDefault,
              defaultValue: hasDefault ? spec['default'] : null,
            ),
          );
        }
      }
      entries.add(
        SavedWorkflowEntry(
          name: name,
          description: desc,
          whenToUse: whenToUse.isEmpty ? null : whenToUse,
          scope: scope,
          path: path,
          args: args,
        ),
      );
    }
  }
  return SavedWorkflowListData(
    entries: entries,
    invalidCount: invalid is List ? invalid.length : 0,
  );
}

/// 实参表单收集与校验（官方 collectSavedWorkflowArgs 逐句镜像）。
/// 空串对 string/number/json 表示不传（有默认值交服务端回填，无默认且必填报错）。
({bool ok, Map<String, dynamic> args, Map<String, String> errors})
collectSavedWorkflowArgs(
  List<SavedWorkflowArgSpec> specs,
  Map<String, String> rawValues,
) {
  final args = <String, dynamic>{};
  final errors = <String, String>{};
  for (final spec in specs) {
    final raw = rawValues[spec.name] ?? '';
    if (spec.type == 'boolean') {
      args[spec.name] = raw == 'true';
      continue;
    }
    if (raw.trim().isEmpty) {
      if (spec.required && !spec.hasDefault) {
        errors[spec.name] = '此参数为必填项';
      }
      continue;
    }
    switch (spec.type) {
      case 'number':
        final n = num.tryParse(raw.trim());
        if (n == null || n.isNaN || n.isInfinite) {
          errors[spec.name] = '请输入有效数字';
        } else {
          args[spec.name] = n;
        }
      case 'json':
        try {
          args[spec.name] = jsonDecode(raw);
        } catch (_) {
          errors[spec.name] = '请输入有效的 JSON 格式';
        }
      default:
        args[spec.name] = raw;
    }
  }
  return (ok: errors.isEmpty, args: args, errors: errors);
}

/// 判断异常是否为旧 CLI 不支持 `workflows/list`（JSON-RPC -32601 / -32602）。
bool isSavedWorkflowListUnsupportedError(Object error) {
  if (error is ChannelRpcError) {
    final data = error.data;
    if (data is Map) {
      final code = data['code'];
      if (code == -32601 || code == -32602 || code == '-32601' || code == '-32602') {
        return true;
      }
    }
  }
  final s = '$error';
  return s.contains('-32601') ||
      s.contains('-32602') ||
      s.contains('method-not-found') ||
      s.contains('Method not found') ||
      s.contains('method not found') ||
      s.contains('Invalid params');
}

/// 将 startSavedWorkflow 拒绝码 / 异常翻译为人话（绝不向用户裸露 reasonCode）。
String savedWorkflowLaunchErrorMessage(String? errorCode) {
  final code = (errorCode ?? '').trim();
  if (code == 'launch_in_flight') {
    return '正在启动工作流，请稍候';
  }
  if (code == 'no_active_workspace') {
    return '当前未连接到活跃工作区，请先打开工作区后再试';
  }
  if (code == 'fault.command.capabilityUnsupported') {
    return '当前桌面端环境未启用动态工作流功能';
  }
  const prefix = 'fault.command.savedWorkflowStartRejected.';
  final reason = code.startsWith(prefix) ? code.substring(prefix.length) : code;
  switch (reason) {
    case 'invalid_name':
      return '工作流名称格式无效';
    case 'not_found':
      return '未找到该工作流，请刷新列表后重试';
    case 'invalid_args':
      return '工作流参数校验未通过，请检查填写内容';
    case 'compile_failed':
      return '工作流脚本编译失败，请在桌面端检查脚本内容';
    case 'session_busy':
      return '会话忙，请稍后重试';
    case 'start_failed':
      return '工作流启动失败，请稍后重试';
    default:
      return '启动工作流失败，请稍后重试';
  }
}

/// 已保存工作流页面：展示当前项目与全局工作流，支持一键启动（含实参表单）。
class SavedWorkflowsPage extends StatefulWidget {
  const SavedWorkflowsPage({super.key});

  @override
  State<SavedWorkflowsPage> createState() => _SavedWorkflowsPageState();
}

class _SavedWorkflowsPageState extends State<SavedWorkflowsPage> {
  bool _loading = true;
  bool _unsupported = false;
  String? _error;
  bool _partialLoadFailed = false;
  List<SavedWorkflowEntry> _projectEntries = const [];
  List<SavedWorkflowEntry> _globalEntries = const [];
  int _invalidCount = 0;

  /// 启动在飞互斥锁（同步事实源，防双击建出两个会话或叠加两个实参弹层）。
  String? _launchingKey;
  bool _sheetOpening = false;
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
      _unsupported = false;
    });
    final app = AppStateScope.of(context);
    SavedWorkflowListData projectData = const SavedWorkflowListData();
    SavedWorkflowListData globalData = const SavedWorkflowListData();
    String? projectErr;
    String? globalErr;
    bool projectUnsupported = false;
    bool globalUnsupported = false;

    await Future.wait([
      () async {
        try {
          final raw = await app.listSavedWorkflows(scope: 'project');
          projectData = parseSavedWorkflowList(raw, fallbackScope: 'project');
        } catch (e) {
          if (isSavedWorkflowListUnsupportedError(e)) {
            projectUnsupported = true;
          } else {
            projectErr = '$e';
          }
        }
      }(),
      () async {
        try {
          final raw = await app.listSavedWorkflows(scope: 'global');
          globalData = parseSavedWorkflowList(raw, fallbackScope: 'global');
        } catch (e) {
          if (isSavedWorkflowListUnsupportedError(e)) {
            globalUnsupported = true;
          } else {
            globalErr = '$e';
          }
        }
      }(),
    ]);
    if (!mounted || gen != _loadGen) return;

    // 仅当两端都不支持、或当前项目不支持且全局无可用条目时判定整页不支持；
    // 若当前项目支持（即使为空列表）仅全局不支持，保留正常空态/项目列表不误报不支持。
    final bothUnsupported =
        (projectUnsupported && globalUnsupported) ||
        (projectUnsupported && globalData.entries.isEmpty && globalErr == null);
    final anyErr = projectErr != null || globalErr != null;
    final hasAnyEntry =
        projectData.entries.isNotEmpty || globalData.entries.isNotEmpty;
    setState(() {
      _loading = false;
      _unsupported = bothUnsupported;
      _projectEntries = projectData.entries;
      _globalEntries = globalData.entries;
      _invalidCount = projectData.invalidCount + globalData.invalidCount;
      _partialLoadFailed = anyErr && hasAnyEntry;
      _error = (anyErr && !hasAnyEntry && !bothUnsupported)
          ? '加载已保存工作流失败，请确认桌面端在线后重试'
          : null;
    });
  }

  Future<void> _onTapRun(SavedWorkflowEntry entry) async {
    if (_launchingKey != null || _sheetOpening) return;
    if (entry.args.isEmpty) {
      await _executeLaunch(entry, const {});
      return;
    }
    _sheetOpening = true;
    Map<String, dynamic>? args;
    try {
      args = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _SavedWorkflowArgsSheet(entry: entry),
      );
    } finally {
      _sheetOpening = false;
    }
    if (!mounted || args == null) return;
    await _executeLaunch(entry, args);
  }

  Future<void> _executeLaunch(
    SavedWorkflowEntry entry,
    Map<String, dynamic> args,
  ) async {
    final key = '${entry.scope}:${entry.name}';
    if (_launchingKey != null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final nav = Navigator.of(context);
    final app = AppStateScope.of(context);
    setState(() => _launchingKey = key);
    try {
      final res = await app.launchSavedWorkflow(
        name: entry.name,
        scope: entry.scope,
        args: args,
      );
      if (!mounted) return;
      if (res.ok && res.sessionId != null) {
        unawaited(
          nav.push(
            MaterialPageRoute(
              builder: (_) => ConversationPage(
                sessionId: res.sessionId!,
                title: entry.name,
              ),
            ),
          ),
        );
        return;
      }
      final msg = savedWorkflowLaunchErrorMessage(res.errorCode);
      final detail = res.errorMessage?.trim() ?? '';
      // compile_failed / invalid_args 时把服务端有界诊断拼在次行供排查。
      final showDetail =
          detail.isNotEmpty &&
          (res.errorCode?.endsWith('compile_failed') == true ||
              res.errorCode?.endsWith('invalid_args') == true);
      messenger?.clearSnackBars();
      final localized = tr(msg);
      final snackText = showDetail
          ? (L10n.resolvedLocale == 'en-US'
                ? '$localized: $detail'
                : '$localized：$detail')
          : localized;
      messenger?.showSnackBar(
        SnackBar(content: Text(snackText, translate: false)),
      );
    } finally {
      if (mounted) setState(() => _launchingKey = null);
    }
  }

  Widget _sectionHeader(BuildContext context, String title, int count) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppType.uiCaption,
              fontWeight: FontWeight.w600,
              color: c.foregroundSubtle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: AppType.uiXs, color: c.foregroundSubtlest),
          ),
        ],
      ),
    );
  }

  Widget _workflowCard(BuildContext context, SavedWorkflowEntry entry) {
    final c = context.colors;
    final key = '${entry.scope}:${entry.name}';
    final launching = _launchingKey == key;
    final busy = _launchingKey != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        key: ValueKey('saved-workflow-${entry.scope}-${entry.name}'),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.borderFaint),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.name,
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
                      if (entry.args.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            border: Border.all(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? c.borderHover
                                  : c.border,
                            ),
                          ),
                          child: Text(
                            '${entry.args.length} 个参数',
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? c.foreground
                                  : c.foregroundSubtle,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (entry.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.description,
                      translate: false,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: c.foregroundSubtle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonal(
              key: ValueKey('saved-workflow-run-${entry.scope}-${entry.name}'),
              onPressed: busy ? null : () => _onTapRun(entry),
              style: FilledButton.styleFrom(
                backgroundColor: c.brandAccent.withValues(alpha: AppAlpha.light),
                foregroundColor: c.brandAccentBright,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                minimumSize: const Size(64, 36),
              ),
              child: launching
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.brandAccentBright,
                      ),
                    )
                  : const Text('运行'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasAny = _projectEntries.isNotEmpty || _globalEntries.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('已保存工作流'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: c.border),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: AppLoading('正在加载已保存工作流…'))
            : _unsupported
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 48),
                  Icon(
                    Icons.account_tree_outlined,
                    size: 40,
                    color: c.foregroundSubtlest,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '当前桌面端版本不支持已保存工作流，请升级桌面端后再试',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      color: c.foregroundSubtle,
                    ),
                  ),
                ],
              )
            : _error != null
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 48),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      color: c.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ),
                ],
              )
            : !hasAny
            ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 48),
                  Icon(
                    Icons.account_tree_outlined,
                    size: 40,
                    color: c.foregroundSubtlest,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无已保存工作流',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                      color: c.foreground,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '在桌面端运行并保存工作流后，可在此一键启动',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      color: c.foregroundSubtle,
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (_projectEntries.isNotEmpty) ...[
                    _sectionHeader(context, '当前项目', _projectEntries.length),
                    for (final e in _projectEntries) _workflowCard(context, e),
                  ],
                  if (_globalEntries.isNotEmpty) ...[
                    _sectionHeader(context, '全局工作流', _globalEntries.length),
                    for (final e in _globalEntries) _workflowCard(context, e),
                  ],
                  if (_partialLoadFailed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        '部分工作流列表加载失败，下拉可重试',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: c.warning,
                        ),
                      ),
                    ),
                  if (_invalidCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        '另有 $_invalidCount 个工作流文件解析失败，请在桌面端检查',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: c.foregroundSubtlest,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// 实参填写弹层（当工作流声明了 args 时打开）。
class _SavedWorkflowArgsSheet extends StatefulWidget {
  const _SavedWorkflowArgsSheet({required this.entry});

  final SavedWorkflowEntry entry;

  @override
  State<_SavedWorkflowArgsSheet> createState() =>
      _SavedWorkflowArgsSheetState();
}

class _SavedWorkflowArgsSheetState extends State<_SavedWorkflowArgsSheet> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _booleans = {};
  Map<String, String> _errors = const {};

  @override
  void initState() {
    super.initState();
    for (final spec in widget.entry.args) {
      final init = spec.initialEditorText();
      if (spec.type == 'boolean') {
        _booleans[spec.name] = init == 'true';
      } else {
        _controllers[spec.name] = TextEditingController(text: init);
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final raw = <String, String>{};
    for (final spec in widget.entry.args) {
      if (spec.type == 'boolean') {
        raw[spec.name] = (_booleans[spec.name] ?? false) ? 'true' : 'false';
      } else {
        raw[spec.name] = _controllers[spec.name]?.text ?? '';
      }
    }
    final res = collectSavedWorkflowArgs(widget.entry.args, raw);
    if (!res.ok) {
      setState(() => _errors = res.errors);
      return;
    }
    Navigator.of(context).pop(res.args);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '运行 ${widget.entry.name}',
                  style: TextStyle(
                    fontSize: AppType.uiBase,
                    fontWeight: FontWeight.w600,
                    color: c.foreground,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final spec in widget.entry.args) ...[
                      if (spec.type == 'boolean')
                        SwitchListTile(
                          key: ValueKey('wf-arg-${spec.name}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(spec.name, translate: false),
                          subtitle: spec.description != null
                              ? Text(
                                  spec.description!,
                                  translate: false,
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: c.foregroundSubtle,
                                  ),
                                )
                              : null,
                          value: _booleans[spec.name] ?? false,
                          onChanged: (v) =>
                              setState(() => _booleans[spec.name] = v),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextField(
                            key: ValueKey('wf-arg-${spec.name}'),
                            controller: _controllers[spec.name],
                            keyboardType: spec.type == 'number'
                                ? const TextInputType.numberWithOptions(
                                    decimal: true,
                                    signed: true,
                                  )
                                : TextInputType.multiline,
                            maxLines: spec.type == 'json' ? 3 : 1,
                            decoration: InputDecoration(
                              labelText: spec.required && !spec.hasDefault
                                  ? '${spec.name} *'
                                  : spec.name,
                              helperText: spec.description,
                              errorText: _errors[spec.name] != null
                                  ? tr(_errors[spec.name]!)
                                  : null,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (_) {
                              if (_errors.containsKey(spec.name)) {
                                setState(() {
                                  _errors = Map.of(_errors)..remove(spec.name);
                                });
                              }
                            },
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('wf-args-submit'),
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.brand,
                      foregroundColor: c.onBrand,
                    ),
                    child: const Text('开始运行'),
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
