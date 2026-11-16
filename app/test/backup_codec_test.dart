// 换机备份编解码层回归（2026-11-16 换机助手批）：
// 回环 / 错口令（GCM 认证失败）/ 篡改不可区分 / kind+版本拒收 / JSON 畸形。
// 全部用 1000 次迭代跑（纯函数层，生产档 150k 由常量锁定，不在此测）。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/backup_codec.dart';

const _fastIterations = 1000;

Map<String, dynamic> _payload() => {
  'accounts': [
    {'id': 'abc123', 'jwt': 'h.p.s', 'provider': 'bigmodel', 'label': '个人号'},
  ],
  'lastUsed': 'abc123',
  'profiles': <Map<String, dynamic>>[],
};

void main() {
  test('回环：加密→解析→解密还原 payload', () async {
    final envelope = await encryptBackup(
      passphrase: 'correct horse 8',
      payload: _payload(),
      iterations: _fastIterations,
    );
    final parsed = parseBackupEnvelope(jsonEncode(envelope));
    final payload = await decryptBackup(
      passphrase: 'correct horse 8',
      envelope: parsed,
      iterationsOverride: _fastIterations,
    );
    expect(payload, _payload());
    expect(envelope['kind'], backupKind);
    expect(envelope['version'], backupVersion);
    expect(envelope['cipher'], 'AES-256-GCM');
  });

  test('错口令：BackupPassphraseError（GCM 认证失败）', () async {
    final envelope = await encryptBackup(
      passphrase: 'correct horse 8',
      payload: _payload(),
      iterations: _fastIterations,
    );
    await expectLater(
      decryptBackup(
        passphrase: 'wrong password',
        envelope: envelope,
        iterationsOverride: _fastIterations,
      ),
      throwsA(isA<BackupPassphraseError>()),
    );
  });

  test('密文被篡改：同样报口令错误/损坏（二者不可区分）', () async {
    final envelope = await encryptBackup(
      passphrase: 'correct horse 8',
      payload: _payload(),
      iterations: _fastIterations,
    );
    final tampered = Map<String, dynamic>.of(envelope)
      ..['ciphertext'] = base64.encode(<int>[
        for (final b in base64.decode(envelope['ciphertext'] as String))
          b ^ 0x01,
      ]);
    await expectLater(
      decryptBackup(
        passphrase: 'correct horse 8',
        envelope: tampered,
        iterationsOverride: _fastIterations,
      ),
      throwsA(isA<BackupPassphraseError>()),
    );
  });

  test('kind 不符 / 版本过高 / JSON 畸形：BackupFormatException', () async {
    final envelope = await encryptBackup(
      passphrase: 'correct horse 8',
      payload: _payload(),
      iterations: _fastIterations,
    );
    expect(
      () => parseBackupEnvelope(
        jsonEncode({...envelope, 'kind': 'other-app-backup'}),
      ),
      throwsA(isA<BackupFormatException>()),
    );
    expect(
      () => parseBackupEnvelope(jsonEncode({...envelope, 'version': 99})),
      throwsA(isA<BackupFormatException>()),
    );
    expect(
      () => parseBackupEnvelope('not json at all'),
      throwsA(isA<BackupFormatException>()),
    );
    // 字段缺失（mac 没了）。
    expect(
      () => parseBackupEnvelope(
        jsonEncode(Map<String, dynamic>.of(envelope)..remove('mac')),
      ),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('随机性：同一 payload 两次加密的 salt/nonce/密文不同', () async {
    final a = await encryptBackup(
      passphrase: 'same pass 12345',
      payload: _payload(),
      iterations: _fastIterations,
    );
    final b = await encryptBackup(
      passphrase: 'same pass 12345',
      payload: _payload(),
      iterations: _fastIterations,
    );
    expect(a['kdf']['salt'], isNot(b['kdf']['salt']));
    expect(a['nonce'], isNot(b['nonce']));
    expect(a['ciphertext'], isNot(b['ciphertext']));
  });

  test('可注入随机源：确定性输出（回归保护）', () async {
    final a = await encryptBackup(
      passphrase: 'deterministic 1',
      payload: _payload(),
      random: Random(42),
      iterations: _fastIterations,
    );
    final b = await encryptBackup(
      passphrase: 'deterministic 1',
      payload: _payload(),
      random: Random(42),
      iterations: _fastIterations,
    );
    expect(a['ciphertext'], b['ciphertext']);
    expect(a['salt'], b['salt']);
  });
}
