// 电脑目录选择弹层（2026-11-19）：project.readDirectory 远程浏览 →
// 选目录返回绝对路径；只列目录（文件过滤）、支持上级导航。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/directory_picker_sheet.dart';

class _PickerApp extends AppState {
  final requested = <String?>[];
  final created = <(String, String)>[];
  final _extraDirs = <String>{};

  @override
  Future<void> createComputerDirectory(String parentPath, String name) async {
    created.add((parentPath, name));
    _extraDirs.add('$parentPath/$name');
  }

  @override
  Future<Map<String, dynamic>> readComputerDirectory(String? path) async {
    requested.add(path);
    if (path == null || path.isEmpty || path == '/home/u') {
      return {
        'path': '/home/u',
        'entries': [
          {'name': 'proj', 'path': '/home/u/proj', 'type': 'directory'},
          {'name': 'notes.txt', 'path': '/home/u/notes.txt', 'type': 'file'},
          {'name': 'zeta', 'path': '/home/u/zeta', 'type': 'directory'},
          for (final d in _extraDirs)
            {'name': d.split('/').last, 'path': d, 'type': 'directory'},
        ],
      };
    }
    return {
      'path': path,
      'entries': [
        {'name': 'sub', 'path': '$path/sub', 'type': 'directory'},
        {'name': 'main.dart', 'path': '$path/main.dart', 'type': 'file'},
      ],
    };
  }
}

void main() {
  testWidgets('目录弹层：只列目录、可进入子目录、确认返回绝对路径', (tester) async {
    final app = _PickerApp();
    String? picked;
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await showDirectoryPickerSheet(context);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 初始 = homedir 列取（path 传 null）
    expect(app.requested.first, isNull);
    expect(find.text('选择电脑目录'), findsOneWidget);
    expect(find.text('/home/u'), findsOneWidget);
    expect(find.text('proj'), findsOneWidget);
    expect(find.text('zeta'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing, reason: '文件不参与选择');

    // 进入子目录
    await tester.tap(find.text('proj'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('/home/u/proj'), findsOneWidget);
    expect(find.text('sub'), findsOneWidget);
    expect(find.text('上级目录'), findsOneWidget);

    // 上级导航
    await tester.tap(find.text('上级目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('/home/u'), findsOneWidget);

    // 再进 proj 并确认
    await tester.tap(find.text('proj'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('dir-pick-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(picked, '/home/u/proj');
  });

  testWidgets('新建文件夹：写入名称 → 创建 → 自动进入新目录', (tester) async {
    final app = _PickerApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDirectoryPickerSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('dir-new-folder')));
    await tester.pumpAndSettle();
    expect(find.text('新建文件夹'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新目录');
    await tester.tap(find.text('创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(app.created, [('/home/u', '新目录')]);
    expect(app.requested.last, '/home/u/新目录', reason: '创建后应进入新目录');
    expect(find.text('/home/u/新目录'), findsOneWidget);
  });

  testWidgets('根目录无上级入口', (tester) async {
    final app = _RootApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDirectoryPickerSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('/'), findsOneWidget);
    expect(find.text('上级目录'), findsNothing);
  });
}

class _RootApp extends AppState {
  @override
  Future<Map<String, dynamic>> readComputerDirectory(String? path) async => {
    'path': '/',
    'entries': [
      {'name': 'etc', 'path': '/etc', 'type': 'directory'},
    ],
  };
}
