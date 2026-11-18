import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 在 1x1 隐藏 WebView 中执行阿里云「无感验证」：
/// 成功返回 captchaVerifyParam；失败/超时返回 null（调用方再打开可见验证页）。
Future<String?> runTracelessCaptcha(
  BuildContext context, {
  required String region,
  required String prefix,
  required String sceneId,
  String language = 'cn',
  Duration timeout = const Duration(seconds: 8),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<String?>();
  final webController = WebViewController();
  OverlayEntry? entry;
  Timer? timer;

  void finish(String? value) {
    if (completer.isCompleted) return;
    timer?.cancel();
    try {
      entry?.remove();
    } catch (_) {}
    entry = null;
    try {
      webController.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    completer.complete(value);
  }

  webController
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.transparent)
    ..addJavaScriptChannel(
      'CaptchaBridge',
      onMessageReceived: (message) {
        dynamic data;
        try {
          data = jsonDecode(message.message);
        } catch (_) {
          return;
        }
        if (data is! Map) return;
        switch ('${data['type'] ?? ''}') {
          case 'success':
            final param = data['param'];
            if (param is String && param.trim().isNotEmpty) {
              finish(param.trim());
            } else {
              finish(null);
            }
            break;
          case 'traceless_failed':
          case 'fail':
          case 'error':
          case 'init_error':
            finish(null);
            break;
        }
      },
    )
    ..loadHtmlString(
      _html(region, prefix, sceneId, language),
      baseUrl: 'https://zcode.z.ai/',
    );

  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: IgnorePointer(
        child: WebViewWidget(controller: webController),
      ),
    ),
  );
  overlay.insert(entry!);
  timer = Timer(timeout, () => finish(null));
  return completer.future;
}

String _html(String region, String prefix, String sceneId, String language) {
  final r = jsonEncode(region);
  final p = jsonEncode(prefix);
  final s = jsonEncode(sceneId);
  final l = jsonEncode(language);
  return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<script>window.AliyunCaptchaConfig = {region: $r, prefix: $p};</script>
<script src="https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js"></script>
</head>
<body style="margin:0;background:transparent">
<button id="captcha-btn" style="position:absolute;left:-9999px;top:-9999px">verify</button>
<div id="captcha-element" style="width:1px;height:1px;overflow:hidden"></div>
<script>
function send(obj) {
  try { CaptchaBridge.postMessage(JSON.stringify(obj)); } catch (e) {}
}
window.addEventListener('load', function () {
  try {
    initAliyunCaptcha({
      SceneId: $s, region: $r, prefix: $p, mode: 'popup', language: $l,
      showErrorTip: false,
      element: '#captcha-element',
      button: '#captcha-btn',
      getInstance: function (instance) {
        send({type: 'ready'});
        try {
          if (typeof instance.startTracelessVerification === 'function') {
            instance.startTracelessVerification();
          } else {
            send({type: 'fail', error: 'traceless_unavailable'});
          }
        } catch (e) {
          send({type: 'fail', error: String((e && e.message) || e)});
        }
      },
      success: function (param) { send({type: 'success', param: param}); },
      fail: function (err) {
        send({type: 'traceless_failed', error: String((err && err.message) || err)});
      },
      onError: function (err) {
        send({type: 'error', error: String((err && err.message) || err)});
      }
    });
  } catch (e) {
    send({type: 'init_error', error: String((e && e.message) || e)});
  }
});
</script>
</body></html>
''';
}
