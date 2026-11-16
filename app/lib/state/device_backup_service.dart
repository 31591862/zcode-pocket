/// 换机备份编排（2026-11-16 换机助手批）：聚合五类本地数据的导出/导入。
///
/// 迁移范围与合并策略（"只补缺、本机优先"——导入可能是旧导出）：
/// - 账号（JWT/provider/备注名）：同 id 跳过；lastUsed 仅本机为空时生效。
/// - 电脑档案：同 deviceSid 跳过（本机可能是刷新过二维码的新档案）；
///   V1 直连档案含 hash 凭据，导出侧默认不带上（UI 显式勾选）。
/// - UI 偏好：键域白名单整键覆盖（后写胜出——偏好无冲突语义，最新快照
///   即用户意图），随后重载内存态。
/// - 草稿/断网队列：按 identity/bucket+id 去重补缺，revision 守护。
///
/// 安全边界：JWT/hash 全程只在内存，导出串经口令加密后才成文件；
/// 分节容错——单节失败计入报告不拖垮整次导入。
library;

import 'dart:convert';
import 'dart:math';

import '../core/backup_codec.dart';
import 'account_store.dart';
import 'draft_store.dart';
import 'profile_store.dart';
import 'send_queue_store.dart';
import 'ui_prefs.dart';

/// 导入报告（UI 逐节展示增量与跳过数）。
class BackupImportReport {
  int accountsAdded = 0;
  int accountsSkipped = 0;
  int profilesAdded = 0;
  int profilesSkipped = 0;
  int profilesInvalid = 0;
  int prefsWritten = 0;
  int draftsAdded = 0;
  int draftsSkipped = 0;
  int queueAdded = 0;
  int queueSkipped = 0;

  /// 单节失败原因（节名→人话）——非空即该节未生效。
  final Map<String, String> errors = {};

  bool get hasErrors => errors.isNotEmpty;
}

/// 换机备份服务：注入五类 store（AppState 持有句柄，设置页取用）。
class DeviceBackupService {
  DeviceBackupService({
    required this.accountStore,
    required this.profileStore,
    required this.uiPrefs,
    this.draftStore,
    this.sendQueueStore,
  });

  final AccountStore accountStore;
  final ProfileStore profileStore;
  final UiPrefs uiPrefs;
  final DraftStore? draftStore;
  final SendQueueStore? sendQueueStore;

  /// 导出：聚合 payload → 口令加密 → envelope JSON 串（调用方写文件/
  /// 分享）。[includeV1Profiles]=带上 V1 直连档案（含 hash 凭据，默认
  /// 不带）；[iterations] 测试缝（生产默认档）。
  Future<String> exportBackup({
    required String passphrase,
    bool includePrefs = true,
    bool includeDrafts = true,
    bool includeSendQueue = true,
    bool includeV1Profiles = false,
    Random? random,
    int iterations = backupKdfIterations,
  }) async {
    final accounts = await accountStore.exportForBackup();
    final profiles = await profileStore.exportForBackup(
      includeV1: includeV1Profiles,
    );
    Map<String, String>? prefs;
    if (includePrefs) prefs = await uiPrefs.exportForBackup();
    List<Map<String, dynamic>>? drafts;
    if (includeDrafts && draftStore != null) {
      drafts = await draftStore!.exportForBackup();
    }
    List<Map<String, dynamic>>? queue;
    if (includeSendQueue && sendQueueStore != null) {
      queue = await sendQueueStore!.exportForBackup();
    }
    final payload = <String, dynamic>{
      'accounts': accounts['accounts'],
      if (accounts['lastUsed'] != null) 'lastUsed': accounts['lastUsed'],
      'profiles': profiles['profiles'],
      if (profiles['activeDeviceSid'] != null)
        'activeDeviceSid': profiles['activeDeviceSid'],
      if (prefs != null && prefs.isNotEmpty) 'prefs': prefs,
      if (drafts != null && drafts.isNotEmpty) 'drafts': drafts,
      if (queue != null && queue.isNotEmpty) 'sendQueue': queue,
    };
    final envelope = await encryptBackup(
      passphrase: passphrase,
      payload: payload,
      random: random,
      iterations: iterations,
    );
    return jsonEncode(envelope);
  }

  /// 导入：解密 → 逐节合并 → 报告。顶层解密失败（口令错/文件损坏/版本
  /// 不符）原样抛 [BackupFormatException]/[BackupPassphraseError] 供 UI
  /// 分文案；分节失败进 [BackupImportReport.errors]。
  Future<BackupImportReport> importBackup({
    required String raw,
    required String passphrase,
    int? iterationsOverride,
  }) async {
    final envelope = parseBackupEnvelope(raw);
    final payload = await decryptBackup(
      passphrase: passphrase,
      envelope: envelope,
      iterationsOverride: iterationsOverride,
    );
    final report = BackupImportReport();

    // ── 账号 ──
    try {
      final accounts = payload['accounts'];
      if (accounts is List) {
        final r = await accountStore.importFromBackup(
          accounts,
          lastUsed: payload['lastUsed'] is String
              ? payload['lastUsed'] as String
              : null,
        );
        report.accountsAdded = r.added;
        report.accountsSkipped = r.skipped;
      }
    } on Object catch (e) {
      report.errors['账号'] = '$e';
    }

    // ── 电脑档案 ──
    try {
      final r = await profileStore.importFromBackup(payload);
      report.profilesAdded = r.added;
      report.profilesSkipped = r.skipped;
      report.profilesInvalid = r.invalid;
    } on Object catch (e) {
      report.errors['电脑档案'] = '$e';
    }

    // ── UI 偏好 ──
    try {
      final prefs = payload['prefs'];
      if (prefs is Map) {
        report.prefsWritten = await uiPrefs.importFromBackup(
          prefs.cast<String, dynamic>(),
        );
      }
    } on Object catch (e) {
      report.errors['设置'] = '$e';
    }

    // ── 草稿 ──
    if (draftStore != null) {
      try {
        final drafts = payload['drafts'];
        if (drafts is List) {
          final r = await draftStore!.importFromBackup(drafts);
          report.draftsAdded = r.added;
          report.draftsSkipped = r.skipped;
        }
      } on Object catch (e) {
        report.errors['草稿'] = '$e';
      }
    }

    // ── 断网队列 ──
    if (sendQueueStore != null) {
      try {
        final queue = payload['sendQueue'];
        if (queue is List) {
          final r = await sendQueueStore!.importFromBackup(queue);
          report.queueAdded = r.added;
          report.queueSkipped = r.skipped;
        }
      } on Object catch (e) {
        report.errors['断网队列'] = '$e';
      }
    }

    return report;
  }
}
