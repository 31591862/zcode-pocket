import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/marketing_catalog.dart';
import 'aliyun_captcha_page.dart';
import 'background_captcha.dart';
import 'app_widgets.dart' show showConfirmDialog;
import 'settings_style.dart';

/// 抽屉底部领取卡片（营销投放 banner）：
/// 直连营销接口取投放 → 手机完成阿里云验证码 → PC 执行领取。
class DrawerClaimCard extends StatefulWidget {
  const DrawerClaimCard({super.key});

  @override
  State<DrawerClaimCard> createState() => _DrawerClaimCardState();
}

class _DrawerClaimCardState extends State<DrawerClaimCard> {
  MarketingPlan? _plan;
  bool _started = false;
  bool _loading = true;
  bool _claiming = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    final plan = await MarketingCatalog.instance.ensureFresh(app);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _loading = false;
    });
  }

  Future<void> _dismiss() async {
    final plan = _plan;
    if (plan == null || _claiming) return;
    final ok = await showConfirmDialog(
      context,
      title: '关闭领取卡片？',
      message: '本次活动机会有限，关闭后可能不再展示这张卡片。',
      confirmLabel: '仍然关闭',
      destructive: false,
    );
    if (!ok || !mounted) return;
    final app = AppStateScope.of(context);
    unawaited(MarketingCatalog.instance.report(app, plan, 'cancel'));
    MarketingCatalog.instance.clear();
    setState(() => _plan = null);
  }

  Future<void> _claim() async {
    final plan = _plan;
    if (plan == null || _claiming) return;
    setState(() => _claiming = true);
    final app = AppStateScope.of(context);

    Map<String, dynamic>? config;
    try {
      config = await app.requestVerificationConfig();
    } catch (_) {}
    final region = '${config?['region'] ?? ''}'.trim();
    final prefix = '${config?['prefix'] ?? ''}'.trim();
    final sceneId = '${config?['sceneId'] ?? ''}'.trim();
    final captchaReady =
        config?['enabled'] != false &&
        region.isNotEmpty &&
        prefix.isNotEmpty &&
        sceneId.isNotEmpty;

    String? captchaParam;
    String? captchaRegion;
    if (captchaReady) {
      // 先尝试后台（1x1 不可见 WebView）无感验证；失败才拉起可见验证页。
      final background = await runTracelessCaptcha(
        context,
        region: region,
        prefix: prefix,
        sceneId: sceneId,
        language: region == 'cn' ? 'cn' : 'en',
      );
      if (background != null) {
        captchaParam = background;
        captchaRegion = region;
      } else {
        final solved = await _solveCaptcha(
          app,
          config: config,
          autoTraceless: false,
        );
        if (solved == null) {
          if (mounted) setState(() => _claiming = false);
          return;
        }
        captchaParam = solved.param;
        captchaRegion = solved.region;
      }
    }

    dynamic result;
    String? error;
    try {
      result = await app.claimManualPlan(
        plan.planId,
        captchaVerifyParam: captchaParam,
        captchaRegion: captchaRegion,
      );
    } catch (e) {
      error = '$e';
    }
    // 配置判断失准时按服务端错误兜底：再走一次可见验证码。
    if (captchaParam == null &&
        error?.toLowerCase().contains('captcha') == true) {
      final solved = await _solveCaptcha(
        app,
        config: config,
        autoTraceless: false,
      );
      if (solved == null) {
        if (mounted) setState(() => _claiming = false);
        return;
      }
      try {
        result = await app.claimManualPlan(
          plan.planId,
          captchaVerifyParam: solved.param,
          captchaRegion: solved.region,
        );
        error = null;
      } catch (e) {
        error = '$e';
      }
    }

    final ok = result is Map && result['success'] == true;
    if (!mounted) return;
    if (ok) {
      unawaited(MarketingCatalog.instance.report(app, plan, 'confirm'));
      unawaited(app.refreshProviderCatalog(force: true));
      MarketingCatalog.instance.clear();
      setState(() {
        _claiming = false;
        _plan = null;
      });
      unawaited(_showSuccess(plan));
      return;
    }
    setState(() => _claiming = false);
    final message =
        error ?? (result is Map ? '${result['message'] ?? ''}' : '');
    unawaited(_showFailure(message));
  }

  Future<({String param, String region})?> _solveCaptcha(
    AppState app, {
    Map<String, dynamic>? config,
    bool autoTraceless = true,
  }) async {
    var resolved = config;
    if (resolved == null) {
      try {
        resolved = await app.requestVerificationConfig();
      } catch (_) {}
    }
    final region = '${resolved?['region'] ?? ''}'.trim();
    final prefix = '${resolved?['prefix'] ?? ''}'.trim();
    final sceneId = '${resolved?['sceneId'] ?? ''}'.trim();
    if (region.isEmpty || prefix.isEmpty || sceneId.isEmpty) return null;
    if (!mounted) return null;
    final param = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AliyunCaptchaPage(
          region: region,
          prefix: prefix,
          sceneId: sceneId,
          language: region == 'cn' ? 'cn' : 'en',
          autoTraceless: autoTraceless,
        ),
      ),
    );
    if (param == null || param.isEmpty) return null;
    return (param: param, region: region);
  }

  Future<void> _showSuccess(MarketingPlan plan) async {
    if (!mounted) return;
    final effective = plan.effectiveAt;
    final buffer = StringBuffer()
      ..writeln(plan.name)
      ..writeln(plan.amountLabel)
      ..writeln(plan.modelName);
    if (effective != null) {
      final local = effective.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      buffer.writeln(
        '将于 ${local.month}月${local.day}日 '
        '${two(local.hour)}:${two(local.minute)} 生效',
      );
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('领取成功'),
        content: Text(buffer.toString().trim()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFailure(String message) async {
    if (!mounted) return;
    final lower = message.toLowerCase();
    final text = lower.contains('already')
        ? '该套餐已经领取过'
        : lower.contains('quota')
        ? '今日领取名额已用完'
        : lower.contains('ineligible')
        ? '当前账号或客户端版本不满足领取条件'
        : lower.contains('unavailable')
        ? '活动已结束或套餐暂不可领取'
        : (message.trim().isEmpty ? '领取失败，请稍后重试' : message);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (_loading || plan == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = context.colors;
    final nameParts = plan.name.trim().split(RegExp(r'\s+'));
    final brand = nameParts.isNotEmpty ? nameParts.first : plan.name;
    final rest = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? kSettingsCardDark : null,
          gradient: isDark
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFEAF2FF), Color(0xFFF3EEFF)],
                ),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white : Colors.black,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Z',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: isDark ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        brand,
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (rest.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            rest,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.foregroundSubtle,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _claiming ? null : _dismiss,
                  icon: const Icon(Icons.close, size: 13),
                  color: colors.foregroundSubtle,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  plan.amountNumberLabel,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1.5),
                  child: Text(
                    plan.unitLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.foregroundSubtle,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${plan.modelName} 额度',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.foregroundSubtle,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: _claiming ? null : _claim,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.foreground,
                    side: BorderSide(
                      color: colors.foreground.withValues(alpha: 0.55),
                      width: 0.8,
                    ),
                    shape: const StadiumBorder(),
                    minimumSize: const Size(0, 26),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: _claiming
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Text('领取', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
