import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'top_notice.dart';

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

  /// 桌面平台（system.info）——Windows 下显示磁盘切换入口。
  String? _platform;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 首帧后再取 AppStateScope（不能在建树中同步读 InheritedWidget）。
    if (_path == null && _loading && _generation == 0) {
      _generation++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _init();
      });
    }
  }

  Future<void> _init() async {
    try {
      final app = AppStateScope.of(context);
      final info = await app.systemInfo();
      if (mounted && info != null) {
        _platform = '${info['platform'] ?? ''}';
      }
    } catch (_) {}
    if (mounted) await _load(null);
  }

  /// Windows：并行探测 A:\-Z:\，返回存在的盘符字母（毫秒级失败，
  /// 不存在的盘立即报错而非超时）。
  Future<List<String>> _probeDrives() async {
    final app = AppStateScope.of(context);
    final letters = 'CDEFGHIJKLMNOPQRSTUVWXYZ'.split('');
    final results = await Future.wait([
      for (final c in letters)
        app
            .readComputerDirectory('$c:\\')
            .then<String?>((_) => c, onError: (_) => null),
    ]);
    final found = [
      for (final r in results)
        if (r != null) r,
    ];
    // C 盘恒在且排最前（探测失败也显示，避免 homedir 所在盘丢失）。
    if (!found.contains('C')) found.insert(0, 'C');
    return found;
  }

  Future<void> _pickDrive() async {
    setState(() => _loading = true);
    final drives = await _probeDrives();
    if (!mounted) return;
    setState(() => _loading = false);
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择磁盘'),
        children: [
          for (final d in drives)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(d),
              child: Row(
                children: [
                  const Icon(Icons.storage_outlined, size: 20),
                  const SizedBox(width: 10),
                  Text('$d:\\'),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && mounted) await _load('$picked:\\');
  }

  /// 直接输入绝对路径跳转（两平台通用）。
  Future<void> _inputPath() async {
    var input = '';
    final typed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入目录路径'),
        content: TextField(
          autofocus: true,
          decoration: InputDecoration(hintText: _path ?? r'例如 D:\projects'),
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
            child: const Text('前往'),
          ),
        ],
      ),
    );
    final target = typed?.trim() ?? '';
    if (target.isEmpty || !mounted) return;
    await _load(target);
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
    if (_platform == 'win32') {
      // Windows：桌面协议无 mkdir；PTY 方案在 Windows 桌面端实测不可用
      // （会话惰死/早退、写入零执行，2026-11-19 三次新会话复现）。
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('暂不支持'),
          content: const Text(
            'Windows 电脑暂不支持在手机上新建文件夹（桌面协议限制）。'
            '请先在电脑上建好文件夹，再回到这里浏览选择；'
            '也可用上层弹层的「新建项目」，在 ZCodeProject 下按名字新建。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
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
      TopNotice.show(message: '名称不能包含路径分隔符');
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
      TopNotice.show(message: '新建文件夹失败：$e');
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
                    if (_platform == 'win32')
                      IconButton(
                        key: const ValueKey('dir-drive'),
                        tooltip: '切换磁盘',
                        icon: const Icon(Icons.storage_outlined, size: 21),
                        onPressed: _loading || _path == null
                            ? null
                            : _pickDrive,
                      ),
                    IconButton(
                      key: const ValueKey('dir-input-path'),
                      tooltip: '输入路径',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: _loading || _path == null ? null : _inputPath,
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
