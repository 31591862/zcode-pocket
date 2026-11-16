// 换机备份服务层回归（2026-11-16 换机助手批）：
// 全链路（旧机导出→新机导入）五节数据还原 / V1 凭据默认不导 / 只补缺
// 合并（本机同 id 账号与同 sid 档案不覆盖）/ 错口令拒收不落数据。
// store 全用内存替身+临时目录，不触碰真实 Keystore。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/backup_codec.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/device_backup_service.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/state/send_queue_store.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

class _MemStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data.remove(key);
}

/// 带 sub claim 的假 JWT（id 派生走 claim 路径）。
String _jwtWithSub(String sub) {
  final payload = base64Url.encode(utf8.encode('{"sub":"$sub"}'));
  return 'h.$payload.s';
}

/// 一台"手机"的完整本地状态（内存替身）。
class _Phone {
  _Phone() {
    _seq++;
    accountStore = AccountStore(storage: _MemStorage());
    profileStore = ProfileStore(
      storage: _MemStorage(),
      debugBackupPath: '${tmp.path}/$_seq/profiles-backup.json',
    );
    uiPrefs = UiPrefs(storage: _MemStorage());
    draftStore = DraftStore(
      Directory('${tmp.path}/$_seq/drafts')..createSync(recursive: true),
    );
    sendQueueStore = SendQueueStore(
      File('${tmp.path}/$_seq/send-queue.json'),
    );
    service = DeviceBackupService(
      accountStore: accountStore,
      profileStore: profileStore,
      uiPrefs: uiPrefs,
      draftStore: draftStore,
      sendQueueStore: sendQueueStore,
    );
  }

  static int _seq = 0;
  static final Directory tmp =
      Directory.systemTemp.createTempSync('device-backup-test');

  late final AccountStore accountStore;
  late final ProfileStore profileStore;
  late final UiPrefs uiPrefs;
  late final DraftStore draftStore;
  late final SendQueueStore sendQueueStore;
  late final DeviceBackupService service;

  static const _v1Url =
      'https://zcode.z.ai/remote/v4?sid=dev-v1&hash=abc&t=1700000000&name=老桌面';
  static const v2Sid = 'dev-v2-sid';
  static const v2AccountId = 'abc123';

  /// 预置：一个账号（sub=abc123）+ 一台 V2 电脑 + 一台 V1 电脑 + 偏好 +
  /// 草稿 + 队列。
  Future<void> seedOldDevice() async {
    await accountStore.save(jwt: _jwtWithSub(v2AccountId), provider: 'bigmodel');
    await profileStore.upsertProfile(
      AccountV2Profile(
        deviceSid: v2Sid,
        deviceName: '主力机',
        accountId: v2AccountId,
        label: '主力机',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        invalid: false,
      ),
    );
    await profileStore.upsertProfile(
      RelayProfile(
        params: CompanionConnectionParams.parse(_v1Url)!,
        label: '老桌面',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1699000000000),
        invalid: false,
      ),
    );
    await uiPrefs.setThemeMode('dark');
    await draftStore.save(
      ComposerDraft(
        identity: DraftIdentity.newDraft(
          deviceSid: v2Sid,
          accountId: v2AccountId,
          workspaceKey: 'ws-1',
          projectId: null,
        ),
        text: '未发送的草稿',
        attachments: const [],
        updatedAt: 1700000000000,
        revision: 3,
      ),
    );
    await sendQueueStore.add(
      SendQueueBucket(
        deviceSid: v2Sid,
        accountId: v2AccountId,
        workspaceKey: 'ws-1',
        scopeId: 'draft:workspace',
      ),
      SendQueueEntry(id: 'q1', text: '排队消息', queuedAt: 1700000000000),
    );
  }
}

void main() {
  test('全链路：旧机导出→新机导入，五节数据还原', () async {
    final old = _Phone();
    await old.seedOldDevice();
    final json = await old.service.exportBackup(
      passphrase: 'move phone 8',
      iterations: 1000,
    );

    final fresh = _Phone();
    final report = await fresh.service.importBackup(
      raw: json,
      passphrase: 'move phone 8',
      iterationsOverride: 1000,
    );
    expect(report.hasErrors, isFalse, reason: '报告：${report.errors}');
    expect(report.accountsAdded, 1);
    // 默认导出不含 V1（凭据=hash），只有 V2 描述符。
    expect(report.profilesAdded, 1);

    // 账号凭据还原 + lastUsed 落位（空机导入）。
    expect(await fresh.accountStore.readJwtFor('abc123'), _jwtWithSub('abc123'));
    expect(await fresh.accountStore.lastUsedAccountId, 'abc123');
    // 电脑档案还原。
    final profiles = await fresh.profileStore.listProfiles();
    expect(profiles.map((p) => p.deviceSid), ['dev-v2-sid']);
    // 偏好还原。
    expect(fresh.uiPrefs.themeMode, 'dark');
    // 草稿/队列还原。
    final draft = await fresh.draftStore.read(
      DraftIdentity.newDraft(
        deviceSid: _Phone.v2Sid,
        accountId: _Phone.v2AccountId,
        workspaceKey: 'ws-1',
        projectId: null,
      ),
    );
    expect(draft?.text, '未发送的草稿');
    final queue = await fresh.sendQueueStore.entries(
      SendQueueBucket(
        deviceSid: _Phone.v2Sid,
        accountId: _Phone.v2AccountId,
        workspaceKey: 'ws-1',
        scopeId: 'draft:workspace',
      ),
    );
    expect(queue.map((e) => e.id), ['q1']);
  });

  test('V1 直连档案默认不导出；显式勾选才带上', () async {
    final old = _Phone();
    await old.seedOldDevice();

    final defaultJson = await old.service.exportBackup(
      passphrase: 'no v1 cred 8',
      iterations: 1000,
    );
    final defaultPayload = await decryptBackup(
      passphrase: 'no v1 cred 8',
      envelope: parseBackupEnvelope(defaultJson),
      iterationsOverride: 1000,
    );
    final defaultProfiles =
        (defaultPayload['profiles'] as List).whereType<Map>().toList();
    expect(defaultProfiles.length, 1, reason: '只有 V2 档案');
    expect(defaultProfiles.single['kind'], 'v2');
    expect(defaultProfiles.single['sid'], 'dev-v2-sid');

    final withV1Json = await old.service.exportBackup(
      passphrase: 'with v1 ok 8',
      includeV1Profiles: true,
      iterations: 1000,
    );
    final withV1Payload = await decryptBackup(
      passphrase: 'with v1 ok 8',
      envelope: parseBackupEnvelope(withV1Json),
      iterationsOverride: 1000,
    );
    final withV1Profiles =
        (withV1Payload['profiles'] as List).whereType<Map>().toList();
    expect(withV1Profiles.length, 2, reason: '显式勾选后 V1 档案随行');
    expect(
      withV1Profiles.any((p) => '${p['url'] ?? ''}'.contains('sid=dev-v1')),
      isTrue,
    );
  });

  test('只补缺：同 id 账号/同 sid 档案不覆盖本机', () async {
    final old = _Phone();
    await old.seedOldDevice();
    final json = await old.service.exportBackup(
      passphrase: 'merge case 8',
      iterations: 1000,
    );

    final target = _Phone();
    // 本机已有同 id 账号（identity 收割路径，jwt 与备份不同）与同 sid 档案。
    await target.accountStore.save(
      jwt: 'plain-token-no-claims',
      provider: 'bigmodel',
      identity: _Phone.v2AccountId,
    );
    await target.profileStore.upsertProfile(
      AccountV2Profile(
        deviceSid: _Phone.v2Sid,
        deviceName: '本机备注',
        accountId: _Phone.v2AccountId,
        label: '本机备注',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1700500000000),
        invalid: false,
      ),
    );
    final report = await target.service.importBackup(
      raw: json,
      passphrase: 'merge case 8',
      iterationsOverride: 1000,
    );
    expect(report.accountsAdded, 0, reason: '同 id 账号跳过');
    expect(report.accountsSkipped, 1);
    expect(report.profilesAdded, 0, reason: '默认导出仅 V2 且同 sid 跳过');
    expect(report.profilesSkipped, 1);
    // 本机 JWT 保留（备份里的旧 token 不覆盖）。
    expect(
      await target.accountStore.readJwtFor(_Phone.v2AccountId),
      'plain-token-no-claims',
    );
    // 本机档案标签保留。
    final merged = await target.profileStore.listProfiles();
    final v2 = merged.where((p) => p.deviceSid == _Phone.v2Sid).single;
    expect(v2.label, '本机备注');
    // 本机已有账号时 lastUsed 不被导入数据改动。
    expect(await target.accountStore.lastUsedAccountId, _Phone.v2AccountId);
  });

  test('错口令导入：BackupPassphraseError，不落任何数据', () async {
    final old = _Phone();
    await old.seedOldDevice();
    final json = await old.service.exportBackup(
      passphrase: 'right pass 123',
      iterations: 1000,
    );
    final fresh = _Phone();
    await expectLater(
      fresh.service.importBackup(
        raw: json,
        passphrase: 'wrong pass !!!',
        iterationsOverride: 1000,
      ),
      throwsA(isA<BackupPassphraseError>()),
    );
    expect(await fresh.accountStore.hasAccount, isFalse);
    expect(await fresh.profileStore.listProfiles(), isEmpty);
  });
}
