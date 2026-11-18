import 'dart:convert';

import 'package:flutter/material.dart' hide Text;
import 'package:webview_flutter/webview_flutter.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';

/// 阿里云验证码（安全验证）——领取前由手机完成验证，换取
/// captchaVerifyParam，再把参数交给桌面端执行领取。
///
/// 配置来源：coding-plan-subscription.getRequestVerificationConfig
/// （region / prefix / sceneId）。SDK 与桌面端一致：
/// https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js
class AliyunCaptchaPage extends StatefulWidget {
  final String region;
  final String prefix;
  final String sceneId;
  final String language; // cn / en

  const AliyunCaptchaPage({
    super.key,
    required this.region,
    required this.prefix,
    required this.sceneId,
    this.language = 'cn',
  });

  @override
  State<AliyunCaptchaPage> createState() => _AliyunCaptchaPageState();
}

class _AliyunCaptchaPageState extends State<AliyunCaptchaPage> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..addJavaScriptChannel(
        'CaptchaBridge',
        onMessageReceived: _onBridgeMessage,
      )
      ..loadHtmlString(_html(), baseUrl: 'https://zcode.z.ai/');
    _controller = controller;
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    dynamic data;
    try {
      data = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (data is! Map) return;
    final type = '${data['type'] ?? ''}';
    switch (type) {
      case 'ready':
        if (mounted) setState(() => _loading = false);
        break;
      case 'success':
        final param = data['param'];
        if (param is String && param.trim().isNotEmpty) {
          Navigator.of(context).pop(param.trim());
          return;
        }
        if (mounted) {
          setState(() => _error = '验证结果为空，请重试');
        }
        break;
      case 'fail':
      case 'error':
      case 'init_error':
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '${data['error'] ?? '验证失败，请重试'}';
          });
        }
        break;
    }
  }

  String _html() {
    final region = jsonEncode(widget.region);
    final prefix = jsonEncode(widget.prefix);
    final sceneId = jsonEncode(widget.sceneId);
    final language = jsonEncode(widget.language);
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>安全验证</title>
<style>
  html, body { margin:0; height:100%; background:#fff;
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  #wrap { display:flex; flex-direction:column; align-items:center;
    justify-content:center; min-height:100%; padding:24px; box-sizing:border-box; }
  h1 { font-size:17px; font-weight:600; margin:0 0 10px; color:#111; }
  p { font-size:13px; line-height:1.6; color:#666; text-align:center;
    margin:0 0 22px; max-width:320px; }
  button { appearance:none; border:0; border-radius:24px; background:#111;
    color:#fff; font-size:15px; padding:12px 44px; }
  #captcha-element { width:100%; }
  #status { margin-top:14px; font-size:12px; color:#999; min-height:16px; }
</style>
<script>
window.AliyunCaptchaConfig = {region: $region, prefix: $prefix};
</script>
<script src="https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js"></script>
</head>
<body>
<div id="wrap">
  <h1>安全验证</h1>
  <p>为保障账号安全，领取前需要完成一次验证。</p>
  <button id="captcha-btn" type="button">开始验证</button>
  <div id="captcha-element"></div>
  <div id="status"></div>
</div>
<script>
function send(obj) {
  try { CaptchaBridge.postMessage(JSON.stringify(obj)); } catch (e) {}
}
window.addEventListener('load', function () {
  var status = document.getElementById('status');
  try {
    initAliyunCaptcha({
      SceneId: $sceneId,
      region: $region,
      prefix: $prefix,
      mode: 'popup',
      language: $language,
      showErrorTip: false,
      element: '#captcha-element',
      button: '#captcha-btn',
      getInstance: function (instance) {
        window.__captchaInstance = instance;
        status.textContent = '点击上方按钮开始验证';
        send({type: 'ready'});
      },
      success: function (param) {
        status.textContent = '验证通过，正在领取…';
        send({type: 'success', param: param});
      },
      fail: function (err) {
        status.textContent = '验证未通过，请重试';
        send({type: 'fail', error: String((err && err.message) || err || '验证未通过')});
      },
      onError: function (err) {
        status.textContent = '验证组件异常，请重试';
        send({type: 'error', error: String((err && err.message) || err || '验证组件异常')});
      }
    });
  } catch (e) {
    status.textContent = '验证组件初始化失败';
    send({type: 'init_error', error: String((e && e.message) || e)});
  }
});
</script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '安全验证',
          style: TextStyle(fontSize: AppType.uiLg),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: Stack(
        children: [
          if (controller != null)
            WebViewWidget(controller: controller)
          else
            const SizedBox.expand(),
          if (_loading)
            const ColoredBox(
              color: Colors.white,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          if (_error != null)
            ColoredBox(
              color: Colors.white,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: AppType.uiBase,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _error = null;
                            _loading = true;
                          });
                          controller?.reload();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
