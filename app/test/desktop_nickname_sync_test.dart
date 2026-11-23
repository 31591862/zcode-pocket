// 桌面端昵称同步（2026-11-24 实验）：官方 oauth.restoreCachedSession
// 返回桌面端已登录账号的 UserInfo（{id, username, displayName}）——
// 手机 WebView 收割的替代/补充来源。锁：①命中账号写入 officialName
// ②旧桌面端无 oauth 通道 → 静默 ③id 不匹配不猜（归属不明不写）。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
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
  }) async => value == null ? data.remove(key) : data[key] = value;
  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);
}

class _FakeChannels extends ChannelClient {
  _FakeChannels({this.result, this.throwOnCall = false})
    : super(sendBody: (_) {});
  final Object? result;
  final bool throwOnCall;
  final calls = <(String, String)>[];
  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((channel, method));
    if (throwOnCall) throw StateError('method not found: $channel.$method');
    return result;
  }
}

class _FakeBridge implements BridgeSession {
  _FakeBridge(this.channels);
  @override
  final ChannelClient channels;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NickApp extends AppState {
  _NickApp({Object? oauthResult, bool throwOnCall = false})
    : accountStore = AccountStore(storage: _MemStorage()) {
    channels = _FakeChannels(result: oauthResult, throwOnCall: throwOnCall);
  }
  late final _FakeChannels channels;
  @override
  final AccountStore accountStore;
  @override
  BridgeSession? get bridge => _FakeBridge(channels);
}

void main() {
  test('oauth.restoreCachedSession 命中 → 昵称写入 officialName', () async {
    final app = _NickApp(
      oauthResult: {
        'id': 'acc-1',
        'username': 'user1',
        'displayName': '小明',
      },
    );
    await app.accountStore.save(
      jwt: 'a.b.c',
      provider: 'bigmodel',
      identity: 'acc-1',
    );
    await app.syncAccountNicknameFromDesktop();
    final accounts = await app.accountStore.listAccounts();
    expect(accounts.single.officialName, '小明');
    expect(accounts.single.displayName, '小明', reason: '展示名回落到官方昵称');
    expect(app.channels.calls, contains(('oauth', 'restoreCachedSession')));
  });

  test('displayName 缺失时回落 username', () async {
    final app = _NickApp(
      oauthResult: {'id': 'acc-1', 'username': 'fallback_user'},
    );
    await app.accountStore.save(
      jwt: 'a.b.c',
      provider: 'bigmodel',
      identity: 'acc-1',
    );
    await app.syncAccountNicknameFromDesktop();
    expect((await app.accountStore.listAccounts()).single.officialName,
        'fallback_user');
  });

  test('旧桌面端无 oauth 通道 → 静默（昵称保持不变）', () async {
    final app = _NickApp(throwOnCall: true);
    await app.accountStore.save(
      jwt: 'a.b.c',
      provider: 'bigmodel',
      identity: 'acc-1',
    );
    await app.syncAccountNicknameFromDesktop();
    expect((await app.accountStore.listAccounts()).single.officialName, '');
  });

  test('重命名/清空重命名保留官方昵称（2026-11-24 真机 bug）', () async {
    final app = _NickApp(
      oauthResult: {'id': 'acc-1', 'displayName': '小明'},
    );
    await app.accountStore.save(
      jwt: 'a.b.c',
      provider: 'bigmodel',
      identity: 'acc-1',
    );
    await app.syncAccountNicknameFromDesktop();
    await app.accountStore.renameAccount('acc-1', '公司号');
    var a = (await app.accountStore.listAccounts()).single;
    expect(a.label, '公司号');
    expect(a.officialName, '小明', reason: '重命名不得丢昵称');

    await app.accountStore.renameAccount('acc-1', '');
    a = (await app.accountStore.listAccounts()).single;
    expect(a.label, '');
    expect(a.officialName, '小明', reason: '清空备注名不得丢昵称');
    expect(a.displayName, '小明', reason: '展示名回落到昵称');
  });

  test('id 不匹配 → 不猜（不写到任何账号）', () async {
    final app = _NickApp(
      oauthResult: {'id': 'other-account', 'displayName': '别人'},
    );
    await app.accountStore.save(
      jwt: 'a.b.c',
      provider: 'bigmodel',
      identity: 'acc-1',
    );
    await app.syncAccountNicknameFromDesktop();
    expect((await app.accountStore.listAccounts()).single.officialName, '');
  });
}
