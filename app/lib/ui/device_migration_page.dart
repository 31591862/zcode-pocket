/// 换机助手（2026-11-16 批）：账号/电脑/设置/草稿/断网队列的加密导出导入。
///
/// 安全红线（页面常驻警示 + 流程内提示）：
/// - 导出文件=完整账号控制权（JWT 可登录手机端全部能力）——口令加密
///   强制、口令不与文件同渠道传、导出后建议立即转发保存并删除本地文件；
/// - V1 直连档案含 hash=永久有效直连凭据，默认不导出，勾选才带上；
/// - 导入合并语义="只补缺、本机优先"，同 id/同 sid 不会覆盖本机凭据。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:path_provider/path_provider.dart';

import '../core/backup_codec.dart';
import '../core/artifact_share.dart';
import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../state/device_backup_service.dart';

/// 入口语义决定页面形态（2026-11-16 用户拍板）：
/// - export：设置入口（已登录=本机有数据，只导出）；
/// - import：登录门入口（新机无数据可导，只导入）。
enum DeviceMigrationMode { export, import }

class DeviceMigrationPage extends StatefulWidget {
  const DeviceMigrationPage({super.key, required this.mode});

  final DeviceMigrationMode mode;

  /// 测试缝（对齐 ConversationPage.debugPickFiles）：注入后替代
  /// FilePicker——回归测试无法走真实平台选择器。
  @visibleForTesting
  static Future<List<PlatformFile>> Function()? debugPickFiles;

  @override
  State<DeviceMigrationPage> createState() => _DeviceMigrationPageState();
}

class _DeviceMigrationPageState extends State<DeviceMigrationPage> {
  final _exportPass1 = TextEditingController();
  final _exportPass2 = TextEditingController();
  final _importPass = TextEditingController();

  /// 导出范围定案（2026-11-16 用户拍板）：只要账号免重登 + 已配对电脑
  /// 自动接通——设置/草稿/断网队列不迁移，V1 hash 凭据永不导出。
  /// 服务层的 include 参数保留（未来按需放开 UI），本页固定全关。
  static const _includePrefs = false;
  static const _includeDrafts = false;
  static const _includeQueue = false;
  static const _includeV1 = false;
  bool _busy = false;
  String? _pickedPath;

  @override
  void dispose() {
    _exportPass1.dispose();
    _exportPass2.dispose();
    _importPass.dispose();
    super.dispose();
  }

  bool get _exportReady =>
      _exportPass1.text.length >= 8 && _exportPass1.text == _exportPass2.text;

  void _setBusy(bool value) {
    if (!mounted) return;
    setState(() => _busy = value);
  }

  // ───────────────────────────────────────────────────────── 导出

  Future<void> _doExport() async {
    final app = AppStateScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    _setBusy(true);
    try {
      final service = DeviceBackupService(
        accountStore: app.accountStore,
        profileStore: app.store,
        uiPrefs: app.uiPrefs,
        draftStore: app.draftStore,
        sendQueueStore: app.sendQueue,
      );
      final json = await service.exportBackup(
        passphrase: _exportPass1.text,
        includePrefs: _includePrefs,
        includeDrafts: _includeDrafts,
        includeSendQueue: _includeQueue,
        includeV1Profiles: _includeV1,
      );
      final cacheDir = await getTemporaryDirectory();
      final target = artifactShareTarget(
        cacheDir,
        'zcode-pocket-backup-${DateTime.now().millisecondsSinceEpoch}.json',
      );
      // FileProvider 只授权 cache/artifacts/ 子目录——首装该目录尚不存在
      // （writeAsString 不建父目录；真机实测 PathNotFoundException）。
      // 对齐 share_flow 的建目录惯例。
      await target.parent.create(recursive: true);
      await target.writeAsString(json, flush: true);
      final ok = await shareArtifactFile(target.path);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? '已调起系统分享。请发送/保存后及时删除该文件'
                : '分享面板调起失败；文件已写入缓存，可稍后重试',
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      _setBusy(false);
    }
  }

  // ───────────────────────────────────────────────────────── 导入

  Future<void> _pickFile() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await (DeviceMigrationPage.debugPickFiles?.call() ??
          FilePicker.pickFiles());
      if (!mounted) return;
      final path = files.isNotEmpty ? files.first.path : null;
      if (path == null || path.isEmpty) return;
      setState(() => _pickedPath = path);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('文件选择器不可用')));
    }
  }

  Future<void> _doImport() async {
    final app = AppStateScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final raw = _pickedPath;
    if (raw == null) return;
    String content;
    try {
      content = await File(raw).readAsString();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('读取文件失败：$e')));
      return;
    }
    if (!mounted) return;
    // 导入前确认（账号钥匙级警示）。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认导入？'),
        content: const Text(
          '导入将把备份中的账号凭据与电脑档案写入本机（只补缺、不覆盖本机已有）。'
          '请确认该文件来源可信——备份文件等于这些账号的完整控制权。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _setBusy(true);
    try {
      final service = DeviceBackupService(
        accountStore: app.accountStore,
        profileStore: app.store,
        uiPrefs: app.uiPrefs,
        draftStore: app.draftStore,
        sendQueueStore: app.sendQueue,
      );
      final report = await service.importBackup(
        raw: content,
        passphrase: _importPass.text,
      );
      if (!mounted) return;
      // 导入后重载档案+接通（登录门场景驱动 HomeShell 翻页进主界面；
      // 设置页场景仅刷新列表，不动现有激活）。
      unawaited(app.refreshAfterBackupImport());
      await _showImportReport(report);
    } on BackupPassphraseError {
      messenger.showSnackBar(
        const SnackBar(content: Text('口令错误或文件已损坏')),
      );
    } on BackupFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('文件无效：$e')));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _showImportReport(BackupImportReport report) {
    final rows = <String>[
      '账号：新增 ${report.accountsAdded}、跳过 ${report.accountsSkipped}',
      '电脑档案：新增 ${report.profilesAdded}、跳过 ${report.profilesSkipped}'
          '${report.profilesInvalid > 0 ? '、损坏 ${report.profilesInvalid}' : ''}',
      '设置：写入 ${report.prefsWritten} 项',
      '草稿：新增 ${report.draftsAdded}、跳过 ${report.draftsSkipped}',
      '断网队列：新增 ${report.queueAdded}、跳过 ${report.queueSkipped}',
      if (report.hasErrors)
        ...report.errors.entries.map((e) => '⚠ ${e.key}：${e.value}'),
    ];
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(row, style: const TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 8),
            Text(
              '新导入的账号或电脑如未立即显示，请完全退出并重新打开应用。',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────── 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('换机助手')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _warningCard(),
                const SizedBox(height: 16),
                // 入口语义=页面形态：登录门只导入，设置只导出。
                switch (widget.mode) {
                  DeviceMigrationMode.export => _exportCard(),
                  DeviceMigrationMode.import => _importCard(),
                },
                const SizedBox(height: 24),
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black38,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('处理中…（口令派生约需数秒）'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _warningCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.tertiary,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '备份文件包含账号登录凭据，等于这些账号的完整控制权。'
              '口令请勿与文件经同一渠道传递；导出并保存后请及时删除分享缓存文件。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _passField({
    required TextEditingController controller,
    required String label,
    String? hint,
    onChanged,
  }) => TextField(
        controller: controller,
        obscureText: true,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged != null ? (_) => onChanged() : null,
      );

  Widget _exportCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导出到新手机',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '账号凭据、已配对电脑（导入后自动接通）；设置/草稿不迁移',
            style: TextStyle(
              fontSize: 12,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 12),
          _passField(
            controller: _exportPass1,
            label: '加密口令（至少 8 位）',
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          _passField(
            controller: _exportPass2,
            label: '确认口令',
            onChanged: () => setState(() {}),
          ),
          if (_exportPass2.text.isNotEmpty && !_exportReady)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _exportPass1.text.length < 8 ? '口令至少 8 位' : '两次口令不一致',
                style: TextStyle(
                  fontSize: 12,
                  color: context.colors.destructive,
                ),
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _exportReady && !_busy ? _doExport : null,
              icon: const Icon(Icons.ios_share, size: 16),
              label: const Text('导出加密文件'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _importCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '从旧手机导入',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '只补缺、不覆盖：本机已有的账号与电脑档案不会被导入数据改动',
            style: TextStyle(
              fontSize: 12,
              color: context.colors.foregroundSubtle,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.folder_open, size: 16),
              label: Text(
                _pickedPath == null ? '选择备份文件' : '已选择：备份文件',
              ),
            ),
          ),
          if (_pickedPath != null) ...[
            const SizedBox(height: 8),
            // onChanged 必须回挂 setState——按钮可用态读 _importPass.text，
            // 不重建则输入后按钮永远停留灰色（真机反馈 2026-11-16）。
            _passField(
              controller: _importPass,
              label: '备份口令',
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _importPass.text.isEmpty || _busy
                    ? null
                    : _doImport,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('开始导入'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
