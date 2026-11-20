import 'dart:convert';

import 'package:flutter/material.dart' hide Text;

import '../core/l10n.dart';
import '../state/app_state_scope.dart';
import 'web_fallback_page.dart';

/// 奖励中心（marketing-claim-1）：官方奖励网页的 App 内入口
/// （设置→功能组）——官方「领取」的完整面（全部 campaign/额度重置/
/// 历史）都在这页，服务端后续新增领取类型免费获得；首页领取卡只覆盖
/// banner 类投放，这里是全集与兜底。
///
/// 契约（官方最新源码快照 rewardsEmbedded.ts:57-66）：URL=
/// `/{cn|en}/rewards?embedded=app&theme=zai-light|zai-dark`。主题/语言
/// 在进页时定档（WebFallbackPage 进页快照；重进页面换档）。
///
/// 凭据注入（marketing-claim-review-1，审查④高2）：共享 localStorage 的
/// `zcodejwttoken` 停留在「上次 OAuth 登录的账号」——多账号/删号后奖励
/// 页会以错误账号操作。修复=官方桌面 rewardsBridge.ts 同款：官方域页面
/// 每次加载完成后清旧凭据键、写入**当前账号** JWT、派发
/// `zcode-rewards-context` 事件（页面桥 onAuthChange 后按新 storage 渲染）。
/// 无账号时清键派发 anonymous（页面回落站内登录）。删号后 WebView 内
/// 残留由本注入在下次进页时覆盖。
class RewardsPage extends StatelessWidget {
  const RewardsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final english = L10n.resolvedLocale == 'en-US';
    final app = AppStateScope.of(context);
    return WebFallbackPage(
      initialUri:
          buildRewardsUri(dark: dark, english: english).toString(),
      title: '奖励中心',
      seedScriptProvider: () async {
        final store = app.accountStore;
        final jwt = await store.readJwtFor(null);
        if (jwt == null || jwt.isEmpty) {
          return buildRewardsSeedScript(
            jwt: null,
            provider: null,
            dark: dark,
            english: english,
          );
        }
        String? provider;
        try {
          final accounts = await store.listAccounts();
          final id = await store.lastUsedAccountId;
          provider = accounts
              .where((a) => a.id == id)
              .firstOrNull
              ?.provider;
        } catch (_) {
          provider = null;
        }
        return buildRewardsSeedScript(
          jwt: jwt,
          provider: provider,
          dark: dark,
          english: english,
        );
      },
    );
  }
}

/// 奖励中心 URL 构造（纯函数供测试；rewardsEmbedded.ts buildRewardsUrl
/// 同款：embedded=app + theme 双档）。
Uri buildRewardsUri({required bool dark, required bool english}) {
  return Uri.https('zcode.z.ai', '${english ? '/en' : '/cn'}/rewards', {
    'embedded': 'app',
    'theme': dark ? 'zai-dark' : 'zai-light',
  });
}

/// 官方域页面注入脚本（rewardsBridge.ts createRewardsInjectionScript +
/// installRewardsPageBridge 语义的手机移植）：清五键→写当前账号凭据→
/// 派发 zcode-rewards-context（页面桥监听后重读 storage）。provider 仅
/// 接受官方枚举（zai/zai_cn/bigmodel），其余（如测试注入档 'injected'）
/// 不写 provider 键——页面按仅 JWT 会话处理。
String buildRewardsSeedScript({
  required String? jwt,
  required String? provider,
  required bool dark,
  required bool english,
}) {
  const clearKeys = [
    'oauth:zai:access_token',
    'oauth:zai_cn:access_token',
    'oauth:bigmodel:access_token',
    'oauth:active_provider',
    'zcodejwttoken',
  ];
  const knownProviders = {'zai', 'zai_cn', 'bigmodel'};
  final writes = <String, String>{
    if (jwt != null && jwt.isNotEmpty) 'zcodejwttoken': jwt,
    if (provider != null && knownProviders.contains(provider))
      'oauth:active_provider': provider,
  };
  final hasCredentials = writes.isNotEmpty;
  final context = {
    'theme': dark ? 'zai-dark' : 'zai-light',
    'locale': english ? 'en-US' : 'zh-CN',
    'auth': {
      'status': hasCredentials ? 'ready' : 'anonymous',
      'provider': hasCredentials &&
              knownProviders.contains(provider)
          ? provider
          : null,
      'revision': DateTime.now().millisecondsSinceEpoch,
    },
  };
  // 值经 jsonEncode 转义后嵌入单引号字符串（jwt 含 . 与 base64 字符，
  // 无单引号风险仍统一转义）。
  final sb = StringBuffer('(function(){try{');
  for (final k in clearKeys) {
    sb.write("localStorage.removeItem('");
    sb.write(k);
    sb.write("');");
  }
  writes.forEach((k, v) {
    sb.write("localStorage.setItem('");
    sb.write(k);
    sb.write("',");
    sb.write(jsonEncode(v));
    sb.write(');');
  });
  sb.write('window.dispatchEvent(new CustomEvent('
      "'zcode-rewards-context',{detail:");
  sb.write(jsonEncode(context));
  sb.write('}));}catch(e){}})();');
  return sb.toString();
}
