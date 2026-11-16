// 换机助手导入按钮可用态回归（2026-11-16 真机反馈"选择备份文件，
// 输入口令后导入按钮是灰色的"）：导入卡口令框此前漏挂 onChanged
// setState——按钮可用态读 _importPass.text，输入后不重建则永远停灰。
// 顺带锁定：选文件后导入节展开、按钮随口令非空点亮、清空回灰。
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/device_migration_page.dart';

/// file_picker 13 的 PlatformFile 是抽象基类，测试自实现
/// （对齐 conversation_page_lifecycle_test 同款桩）。
base class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this.name);
  @override
  final String name;
  @override
  Uri get uri => Uri.file('/tmp/$name');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => 1;
  @override
  Future<int?> length() async => 1;
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([65]);
  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList([65]));
}

class _GateApp extends AppState {
  @override
  bool get loaded => true;
}

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    AppStateScope(
      app: _GateApp(),
      child: const MaterialApp(home: DeviceMigrationPage()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

FilledButton _importButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '开始导入'),
    );

void main() {
  testWidgets('选文件→口令非空点亮导入按钮；清空回灰', (tester) async {
    DeviceMigrationPage.debugPickFiles = () async =>
        [_FakePlatformFile('zcode-pocket-backup.json')];
    addTearDown(() => DeviceMigrationPage.debugPickFiles = null);
    await _pumpPage(tester);

    // 未选文件：导入节未展开（按钮不存在）。
    expect(find.text('开始导入'), findsNothing);

    await tester.tap(find.text('选择备份文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 已选文件、口令空：按钮存在但禁用（修复前的用户所见）。
    final before = _importButton(tester);
    expect(before.onPressed, isNull, reason: '口令为空必须禁用');

    // 输入口令：按钮点亮（修复前：漏 onChanged 不重建，恒灰）。
    await tester.enterText(
      find.widgetWithText(TextField, '备份口令'),
      'test pass 123',
    );
    await tester.pump();
    final enabled = _importButton(tester);
    expect(enabled.onPressed, isNotNull, reason: '口令非空必须点亮导入按钮');

    // 清空口令：回灰。
    await tester.enterText(
      find.widgetWithText(TextField, '备份口令'),
      '',
    );
    await tester.pump();
    expect(_importButton(tester).onPressed, isNull, reason: '口令清空必须回灰');
  });
}
