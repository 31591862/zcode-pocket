import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// 电脑目录选择弹层（2026-11-19 实证 project.readDirectory 远程开放）：
/// 浏览桌面文件系统选一个目录作为项目根。返回选中目录的绝对路径；
/// 取消返回 null。
Future<String?> showDirectoryPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const DirectoryPickerSheet(),
  );
}

class DirectoryPickerSheet extends StatefulWidget {
  const DirectoryPickerSheet({super.key});

  @override
  State<DirectoryPickerSheet> createState() => _DirectoryPickerSheetState();
}

class _DirectoryPickerSheetState extends State<DirectoryPickerSheet> {
  String? _path;
  List<Map<String, dynamic>> _dirs = const [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首帧后再取 AppStateScope（不能在建树中同步读 InheritedWidget）。
    if (_path == null && _loading && _generation == 0) {
      _generation++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(null);
      });
    }
  }

  Future<void> _load(String? path) async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = AppStateScope.of(context);
      final res = await app.readComputerDirectory(path);
      if (!mounted || gen != _generation) return;
      final rawPath = res['path'];
      final entries = res['entries'];
      final dirs = <Map<String, dynamic>>[];
      if (entries is List) {
        for (final e in entries) {
          if (e is Map && '${e['type']}' == 'directory') {
            dirs.add(e.cast<String, dynamic>());
          }
        }
      }
      dirs.sort(
        (a, b) => '${a['name']}'.toLowerCase().compareTo(
          '${b['name']}'.toLowerCase(),
        ),
      );
      setState(() {
        _path = rawPath is String ? rawPath : path;
        _dirs = dirs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _joinPath(String parent, String name) {
    final sep = parent.contains('\\') && !parent.contains('/') ? '\\' : '/';
    if (parent.endsWith('/') || parent.endsWith('\\')) return '$parent$name';
    return '$parent$sep$name';
  }

  Future<void> _createFolder() async {
    final parent = _path;
    if (parent == null) return;
    // 不用 TextEditingController（弹窗路由退场期间仍持有——提前
    // dispose 会触发 used-after-dispose）；onChanged 捕获最终文本。
    var input = '';
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onChanged: (v) => input = v,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(input),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final trimmed = name.trim();
    if (RegExp(r'[\\/]').hasMatch(trimmed)) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('名称不能包含路径分隔符')));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = AppStateScope.of(context);
      await app.createComputerDirectory(parent, trimmed);
      if (!mounted) return;
      await _load(_joinPath(parent, trimmed));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('新建文件夹失败：$e')));
    }
  }

  /// 上级目录（兼容 / 与 \ 分隔符；根目录返回 null）。
  String? _parentOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final p = path.replaceAll('\\', '/');
    final trimmed = p.length > 1 && p.endsWith('/')
        ? p.substring(0, p.length - 1)
        : p;
    // 已是根（/ 或盘符 C:）——无上级入口。
    if (trimmed == '/' || RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) {
      return null;
    }
    final idx = trimmed.lastIndexOf('/');
    if (idx < 0) return null;
    if (idx == 0) return '/';
    final parent = trimmed.substring(0, idx);
    if (RegExp(r'^[A-Za-z]:$').hasMatch(parent)) return '$parent\\';
    return parent;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final maxH = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        // Material 承载底色（ListTile ink/背景需要最近的 Material 同级）。
        child: Material(
          color: colors.card,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.card),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选择电脑目录',
                        style: TextStyle(
                          fontSize: AppType.uiBase,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('dir-new-folder'),
                      tooltip: '新建文件夹',
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 22,
                      ),
                      onPressed: _loading || _error != null || _path == null
                          ? null
                          : _createFolder,
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // 当前路径
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.sidebar,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    _path ?? '…',
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: colors.foregroundSubtle,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 28,
                                color: colors.destructive,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tr('读取目录失败：$_error'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppType.uiCaption,
                                  color: colors.foregroundSubtle,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: () => _load(_path),
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          if (_parentOf(_path) case final parent?)
                            ListTile(
                              key: const ValueKey('dir-up'),
                              leading: const Icon(Icons.arrow_upward, size: 20),
                              title: const Text('上级目录'),
                              dense: true,
                              onTap: () => _load(parent),
                            ),
                          for (final d in _dirs)
                            ListTile(
                              key: ValueKey('dir-${d['path']}'),
                              leading: Icon(
                                '${d['isSymbolicLink']}' == 'true'
                                    ? Icons.link
                                    : Icons.folder_outlined,
                                size: 20,
                                color: colors.brandAccent,
                              ),
                              title: Text(
                                '${d['name']}',
                                translate: false,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              dense: true,
                              onTap: () => _load('${d['path']}'),
                            ),
                          if (!_loading && _dirs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                tr('此目录下没有子目录'),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: AppType.uiCaption,
                                  color: colors.foregroundSubtle,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: FilledButton.icon(
                  key: const ValueKey('dir-pick-confirm'),
                  onPressed: (_path == null || _loading || _error != null)
                      ? null
                      : () => Navigator.of(context).pop(_path),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('用此目录新建项目'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
