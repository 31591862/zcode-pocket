// 换机助手登录门入口回归（2026-11-16 用户报告"这个界面没有导入功能
// 我怎么迁移"）：新手机首装正停在登录门（PairingPage）——换机助手
// 主入口在设置页，登录门根本进不去设置。修复：PairingPage 底部加
// 「从旧手机恢复」入口；导入成功经 app.refreshAfterBackupImport 重载
// 档案并接通，HomeShell（profiles 非空即翻页）自动进主界面。
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/home_shell.dart';
import 'package:zcode_pocket/ui/pairing_page.dart';

class _MemStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value,
      AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
      WebOptions? webOptions, AppleOptions? mOptions,
      WindowsOptions? wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}

/// 空档案手机：loaded=true（启动门逻辑已跑完），无档案 → HomeShell 落
/// PairingPage。bridge 不覆写（默认 null）——导入入口是纯导航，不连接。
/// activate 覆写只记录不触栈（真栈在测试环境会挂常驻连接定时器）。
class _GateApp extends AppState {
  _GateApp() : super(store: ProfileStore(storage: _MemStorage()));
  @override
  bool get loaded => true;
  String? activatedSid;
  @override
  Future<void> activate(DeviceProfile profile) async {
    activatedSid = profile.deviceSid;
  }
}

void main() {
  // 换机助手页是长 ListView（懒构建）：调高测试表面让导入卡进树。
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> _pumpGate(WidgetTester tester, AppState app) async {
    await tester.binding.setSurfaceSize(const Size(412, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      AppStateScope(app: app, child: const MaterialApp(home: HomeShell())),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('登录门可见「从旧手机恢复」入口，点进换机助手页', (tester) async {
    final app = _GateApp();
    await _pumpGate(tester, app);

    expect(find.byType(PairingPage), findsOneWidget,
        reason: '基线：空档案手机落在登录门');
    expect(find.byKey(const ValueKey('pairing-migration-entry')),
        findsOneWidget, reason: '修复前登录门无任何导入路径（死锁）');

    await tester.tap(find.byKey(const ValueKey('pairing-migration-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('换机助手'), findsOneWidget,
        reason: '入口直达换机助手页');
    // 入口语义=页面形态：登录门只有导入，无导出（新机无数据可导）。
    expect(find.text('从旧手机导入'), findsOneWidget);
    expect(find.text('导出到新手机'), findsNothing);
  });

  testWidgets('导入成功路径的刷新方法：档案重载后 HomeShell 翻页', (tester) async {
    final app = _GateApp();
    await _pumpGate(tester, app);
    expect(find.byType(PairingPage), findsOneWidget);

    // 模拟换机助手导入完成后的落盘态：档案在加密存储、activeDeviceSid
    // 已由导入侧写入（ProfileStore.upsertProfile 走导入同款写路径）。
    await app.store.upsertProfile(
      AccountV2Profile(
        deviceSid: 'imported-sid',
        deviceName: '导入的电脑',
        label: '导入的电脑',
        addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        invalid: false,
      ),
    );
    await app.store.setActiveDeviceSid('imported-sid');

    // 导入成功回调：重载档案。activate 会尝试真实连接（测试环境无桥，
    // 失败被 contained 吞掉）——门翻页判据只看 profiles 非空。
    await app.refreshAfterBackupImport();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(app.profiles.map((p) => p.deviceSid), contains('imported-sid'),
        reason: '导入的档案必须进内存态（否则门永不翻页）');
    expect(app.activatedSid, 'imported-sid',
        reason: '空机导入后必须按 activeDeviceSid 接通导入的电脑');
  });
}
