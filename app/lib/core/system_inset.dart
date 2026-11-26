// 系统底部安全区直推通道（dual-pane-collapse-2 r3，vivo 任务栏遮挡终局）。
//
// 背景：vivo 展开态任务栏在原生 rootWindowInsets 里正常上报
//（navBars bottom=169px，zb-insets 探针实证），但 Flutter 的
// MediaQuery.viewPadding 拿到 0（透传链在 vivo 上断裂——探针/截图
// 双证：左栏间距 0 被遮、右栏正常=视口全屏而 Dart 安全区值缺失）。
// 不再赌框架透传：原生侧监听 decorView 的 insets 变化，把底部值
//（systemBars∪navigationBars∪displayCutout 取最大，逻辑 dp）实时
// 推给本模块；消费方取 max(MediaQuery.viewPadding.bottom, 本值)。
//
// 任务栏开/关、折叠/展开都会触发 insets 变化→实时跟随；键盘（ime
// 类型）不掺入（键盘弹出时多留的部分在键盘后面不可见，无可感知副作用）。
//
// 同一通道还承载小窗顶栏高度的直推，与根层钳制异常顶部 padding 的守卫
// （2026-11-25，文件后半）：Flutter 引擎在 Android 15+ 把窗口 captionBar
// 的全部矩形并进顶部安全区，部分 ROM 的小窗因此把整页推出可视区。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 原生推送的底部安全区（逻辑 dp；0=未推送/无系统栏）。
final ValueNotifier<double> systemInsetBottomDp = ValueNotifier(0);

/// 原生推送的小窗顶栏高度（captionBar 的 top inset，逻辑 dp；0=无顶栏/
/// 未推送/Android 11 以下）。消费方：[clampFreeformTopPadding] 的钳制
/// 目标值。
final ValueNotifier<double> systemCaptionTopDp = ValueNotifier(0);

bool _initialized = false;

/// 注册原生反向推送（幂等；main 启动早期调用一次即可，未初始化的
/// 消费场景回落 MediaQuery——不比现状差）。
void initSystemInsetBridge() {
  if (_initialized) return;
  _initialized = true;
  const MethodChannel('companion/notify').setMethodCallHandler((call) async {
    if (call.method == 'systemInsetChanged') {
      final v = call.arguments;
      if (v is num) {
        systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
      }
    }
    if (call.method == 'captionInsetChanged') {
      final v = call.arguments;
      if (v is num) {
        systemCaptionTopDp.value = v.toDouble().clamp(0, 200);
      }
    }
    return null;
  });
  refreshSystemInset();
  refreshCaptionInset();
}

/// 主动拉一次当前底部安全区——listener 首次推送常落在 Dart 就绪前
/// （变化驱动+任务栏常驻无变化=永久丢失，候选 06 真机实证）。init 调
/// 一次；失败静默（回落 MediaQuery 路径不劣于现状）。
Future<void> refreshSystemInset() {
  return const MethodChannel('companion/notify')
      .invokeMethod<num>('currentSystemInset')
      .then((v) {
    if (v != null) systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
  }).catchError((_) {});
}

/// 主动拉一次当前小窗顶栏高度（与 [refreshSystemInset] 同款首推丢失
/// 兜底；没有该方法的平台 MissingPlugin 静默，值保持 0）。
Future<void> refreshCaptionInset() {
  return const MethodChannel('companion/notify')
      .invokeMethod<num>('currentCaptionInset')
      .then((v) {
    if (v != null) systemCaptionTopDp.value = v.toDouble().clamp(0, 200);
  }).catchError((_) {});
}

/// 小窗异常顶部 padding 钳制。
///
/// 根因：Flutter 引擎（Android 15+）把窗口 captionBar 的全部矩形并进
/// 顶部安全区——逐矩形取 max(viewPaddingTop, rect.bottom)，并假定
/// captionBar 只出现在窗口顶部（引擎源码注释写明了这个前提）。部分 ROM
/// 的小窗额外上报底部拖拽把手，其矩形 bottom≈窗口高 → padding.top≈
/// 窗口高 → 页面整体被推出可视区（上游 flutter/flutter#161086 未修）。
///
/// 判据：顶部 padding 超过窗口高一半即异常（状态栏/顶栏不可能占半窗）；
/// 正常路径原样返回同一实例（零变化）。目标值=原生直推的真实顶栏高度
/// （[systemCaptionTopDp]）；未推送时取 0——宁可内容顶到顶栏下面，也不
/// 整页白屏。padding 与 viewPadding 同钳（消费方两者都用）。
MediaQueryData clampFreeformTopPadding(MediaQueryData mq, double captionTopDp) {
  if (mq.size.height <= 0 || mq.padding.top <= mq.size.height / 2) return mq;
  final sane = captionTopDp.clamp(0.0, mq.size.height / 2);
  return mq.copyWith(
    padding: mq.padding.copyWith(top: sane),
    viewPadding: mq.viewPadding.copyWith(top: sane),
  );
}

/// 根层守卫（挂 MaterialApp.builder，覆盖全部路由/弹层）：顶栏高度推送
/// 到达时重建 MediaQuery，钳掉异常的顶部 padding。正常状态下不改变任何
/// 布局输入。
class FreeformTopPaddingGuard extends StatelessWidget {
  const FreeformTopPaddingGuard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: systemCaptionTopDp,
      builder: (context, captionTop, _) => MediaQuery(
        data: clampFreeformTopPadding(MediaQuery.of(context), captionTop),
        child: child,
      ),
    );
  }
}
