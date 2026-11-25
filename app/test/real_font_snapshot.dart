// 真字体渲染采集（发布前人工目检用）。
//
// 游览/金样管线用的测试字体是方块字（文字与图标都渲成等高方块）——文字
// 层不可签收。本助手在字体文件可得的机器上加载系统中日韩字体与图标
// 字体，把页面按真机像素比渲成 PNG 落盘，供人工目检。
// 字体不可得（CI/其他机器）=采集整体跳过，调用方的断言照常执行。
//
// 用法：setUpAll(loadRealFonts)；页面用 reviewTheme() 建主题、根节点包
// RepaintBoundary(key: realFontShotKey)；断言后
// `await snapWithRealFonts(tester, '<画面名>')`。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';

const realFontFamily = 'ZpReviewFont';

/// 截图边界（页面根节点；弹层画在根 Overlay 内，一并入画）。
const realFontShotKey = ValueKey('real-font-shot');

bool _loaded = false;
bool _checked = false;

bool get realFontsLoaded => _loaded;

ByteData? _readFirst(List<String> candidates) {
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return ByteData.view(file.readAsBytesSync().buffer);
    }
  }
  return null;
}

/// 加载真字体（幂等；同步读盘须在 testWidgets 体外的 setUpAll 调用）。
Future<void> loadRealFonts() async {
  if (_checked) return;
  _checked = true;
  final cjk = _readFirst(const [
    'C:/Windows/Fonts/NotoSansSC-VF.ttf',
    'C:/Windows/Fonts/msyh.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/System/Library/Fonts/PingFang.ttc',
  ]);
  if (cjk == null) return;
  final sdk = Platform.environment['FLUTTER_ROOT'];
  final icons = _readFirst([
    if (sdk != null && sdk.isNotEmpty)
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
  await (FontLoader(realFontFamily)..addFont(Future.value(cjk))).load();
  if (icons != null) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
  }
  _loaded = true;
}

/// 评审主题：真字体注入全部字阶；字体未加载=原主题（断言不受影响）。
ThemeData reviewTheme(Brightness brightness) {
  final base = buildAppTheme(brightness);
  if (!_loaded) return base;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: realFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: realFontFamily,
    ),
  );
}

/// 把 [realFontShotKey] 边界内的画面按手机像素比（3x）渲成 PNG，落到
/// 仓库内的一次性留证目录（默认路径见下方，不提交；可用环境变量
/// ZP_REAL_FONT_REVIEW_DIR 改写）。字体未加载=直接返回。
Future<void> snapWithRealFonts(WidgetTester tester, String name) async {
  if (!_loaded) return;
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(realFontShotKey),
  );
  // toImage 走引擎真实异步——假时钟测试环境里须 runAsync 放行。
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  });
  if (bytes == null) return;
  final dir = Directory(
    Platform.environment['ZP_REAL_FONT_REVIEW_DIR'] ??
        '../tools/logs/real-font-review',
  );
  dir.createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes);
}
