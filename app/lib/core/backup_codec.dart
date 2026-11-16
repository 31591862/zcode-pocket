/// 换机备份编解码纯函数层（2026-11-16 换机助手批）。
///
/// 安全模型：导出文件=完整账号钥匙（JWT 可登录手机端全部能力），必须
/// 口令加密落盘。AES-256-GCM 认证加密（篡改/错口令在解密期即失败）+
/// PBKDF2-HMAC-SHA256 口令派生（纯 Dart，15 万次迭代=手机端一次性
/// 操作秒级可接受；brute-force 离线面由用户口令强度主导）。
///
/// envelope（落盘 JSON）：
/// ```
/// { kind, version, createdAt,
///   kdf: {algo, iterations, salt(b64)},
///   cipher: 'AES-256-GCM', nonce(b64), mac(b64), ciphertext(b64) }
/// ```
/// payload（加密前 JSON）：accounts/lastUsed/profiles/activeDeviceSid/
/// prefs/drafts/sendQueue——结构校验归 DeviceBackupService，本层只管
/// 密封与开箱。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// kind 不匹配=非本应用备份（拒收，防止拿别的文件碰运气解密）。
const backupKind = 'zcode-pocket-backup';

/// envelope 版本（结构性破坏才升）。
const backupVersion = 1;

/// PBKDF2 迭代档：150k（OWASP 2023 推荐的 1/4，纯 Dart 手机端一次性
/// 操作控制在秒级；口令强度仍是第一防线，UI 明示）。
const backupKdfIterations = 150000;

const _cipherAlgoName = 'AES-256-GCM';
const _kdfAlgoName = 'PBKDF2-HMAC-SHA256';

final AesGcm _aesGcm = AesGcm.with256bits();

/// 编码层异常：JSON 畸形/kind 不符/版本不识别/字段缺失。
class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 口令错误或密文被篡改（GCM 认证失败——两者不可区分，同文案上报）。
class BackupPassphraseError implements Exception {
  const BackupPassphraseError();
  @override
  String toString() => '口令错误或文件已损坏';
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));

String _b64(Uint8List bytes) => base64.encode(bytes);

Uint8List _unb64(String raw, String field) {
  try {
    return Uint8List.fromList(base64.decode(raw));
  } on FormatException {
    throw BackupFormatException('字段 $field 不是合法 base64');
  }
}

/// 解析并校验 envelope 顶层结构（JSON 串→Map）。kind/版本不符即拒。
Map<String, dynamic> parseBackupEnvelope(String raw) {
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw BackupFormatException('不是合法 JSON：$e');
  }
  if (decoded is! Map) throw BackupFormatException('顶层不是 JSON 对象');
  final envelope = decoded.cast<String, dynamic>();
  if ('${envelope['kind'] ?? ''}' != backupKind) {
    throw BackupFormatException('不是 $backupKind 备份文件');
  }
  final version = envelope['version'];
  if (version is! num || version.toInt() > backupVersion) {
    throw BackupFormatException('备份版本不受支持（$version）');
  }
  if (version.toInt() < backupVersion) {
    throw BackupFormatException('备份版本过旧（$version）');
  }
  final kdf = envelope['kdf'];
  if (kdf is! Map ||
      '${kdf['algo'] ?? ''}' != _kdfAlgoName ||
      kdf['iterations'] is! num ||
      kdf['salt'] is! String ||
      '${envelope['cipher'] ?? ''}' != _cipherAlgoName ||
      envelope['nonce'] is! String ||
      envelope['mac'] is! String ||
      envelope['ciphertext'] is! String) {
    throw BackupFormatException('envelope 结构不完整');
  }
  return envelope;
}

/// 密封 payload → envelope Map（调用方 jsonEncode 落盘）。
Future<Map<String, dynamic>> encryptBackup({
  required String passphrase,
  required Map<String, dynamic> payload,
  Random? random,
  int iterations = backupKdfIterations,
}) async {
  if (passphrase.isEmpty) {
    throw ArgumentError('passphrase 为空');
  }
  final rng = random ?? Random.secure();
  final salt = _randomBytes(rng, 16);
  final nonce = _randomBytes(rng, 12);
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  final secretKey = await kdf.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
  final clearText = utf8.encode(jsonEncode(payload));
  final box = await _aesGcm.encrypt(
    clearText,
    secretKey: secretKey,
    nonce: nonce,
  );
  return {
    'kind': backupKind,
    'version': backupVersion,
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'kdf': {
      'algo': _kdfAlgoName,
      'iterations': iterations,
      'salt': _b64(salt),
    },
    'cipher': _cipherAlgoName,
    'nonce': _b64(nonce),
    'mac': _b64(Uint8List.fromList(box.mac.bytes)),
    'ciphertext': _b64(Uint8List.fromList(box.cipherText)),
  };
}

/// 开箱 envelope → payload Map。错口令/篡改（GCM 认证失败）抛
/// [BackupPassphraseError]；结构问题抛 [BackupFormatException]。
Future<Map<String, dynamic>> decryptBackup({
  required String passphrase,
  required Map<String, dynamic> envelope,
  int? iterationsOverride,
}) async {
  final kdfMap = envelope['kdf'];
  if (kdfMap is! Map) throw BackupFormatException('envelope 结构不完整');
  final iterations = iterationsOverride ??
      ((kdfMap['iterations'] as num?)?.toInt() ?? backupKdfIterations);
  final salt = _unb64(kdfMap['salt'] as String, 'salt');
  final nonce = _unb64(envelope['nonce'] as String, 'nonce');
  final mac = _unb64(envelope['mac'] as String, 'mac');
  final cipherText = _unb64(envelope['ciphertext'] as String, 'ciphertext');
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  final secretKey = await kdf.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
  final List<int> clearBytes;
  try {
    clearBytes = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: secretKey,
    );
  } on SecretBoxAuthenticationError {
    throw const BackupPassphraseError();
  }
  dynamic payload;
  try {
    payload = jsonDecode(utf8.decode(clearBytes));
  } on Object {
    throw BackupFormatException('密文载荷不是合法 JSON');
  }
  if (payload is! Map) throw BackupFormatException('载荷不是 JSON 对象');
  return payload.cast<String, dynamic>();
}
