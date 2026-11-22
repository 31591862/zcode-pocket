// 运行中收到新消息 锚定下拉（2026-11-22 SimpleDialog 退役）：点行弹菜单、
// 条目选择落盘 followupMode。
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';

import 'package:zcode_pocket/ui/settings_conversation_page.dart';

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

class _RecordingChannels extends ChannelClient {
  _RecordingChannels() : super(sendBody: (_) {});
  final calls = <(String, String, List<Object?>)>[];
  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((channel, method, args));
    return null;
  }
}

class _SyncBridge implements BridgeSession {
  _SyncBridge(this.channels);
  @override
  final ChannelClient channels;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FollowupApp extends AppState {
  _FollowupApp(this.recorder) : uiPrefs = UiPrefs(storage: _MemStorage());
  final _RecordingChannels recorder;
  @override
  final UiPrefs uiPrefs;
  @override
  BridgeSession? get bridge => _SyncBridge(recorder);
}

void main() {
  testWidgets('点行弹锚定菜单，选队列生效', (tester) async {
    final recorder = _RecordingChannels();
    final app = _FollowupApp(recorder);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(home: SettingsConversationPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('运行中收到新消息'));
    await tester.pump(const Duration(milliseconds: 300));
    // 菜单弹出：两枚条目（带 key）挂根 Overlay。
    expect(tester.any(find.byKey(const ValueKey('followup-queue'))), isTrue);
    expect(tester.any(find.byKey(const ValueKey('followup-guide'))), isTrue);

    await tester.tap(find.byKey(const ValueKey('followup-queue')));
    await tester.pumpAndSettle();
    // 菜单收起 + 选择生效。
    expect(tester.any(find.byKey(const ValueKey('followup-queue'))), isFalse);
    // 夹具无活跃会话（conversation==null）→ 只落盘偏好，不下发 RPC。
    expect(recorder.calls, isEmpty);
    expect(app.uiPrefs.followupMode, 'queue');
  });
}
