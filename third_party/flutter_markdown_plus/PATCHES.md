# flutter_markdown_plus（本地补丁版 1.0.12）

上游：https://github.com/foresightmobile/flutter_markdown_plus
（MIT，见 LICENSE）。本目录为 pub 缓存 1.0.12 副本，**仅一处**改动。

## 补丁

`lib/src/builder.dart` → `_buildRichText` 的 `StrutStyle` 增加：

```dart
leadingDistribution: TextLeadingDistribution.even,
```

原因：包对所有文本块强制 `forceStrutHeight: true` 的行盒；默认
proportional 按字体 ascent/descent 比例分配行高余量，安卓中文字体的
上下不对称会被行高放大——行内选中时上/下留白不等（2026-11-19 真机
反馈）。even 把余量对半分配，与用户气泡的文本行距观感一致。

## 升级流程

1. 用新版覆盖 `third_party/flutter_markdown_plus`（保留本文件）；
2. 把上述一行重新加进 `_buildRichText` 的 `StrutStyle`；
3. `flutter pub get`，跑 `flutter test test/code_highlight_test.dart
   test/assistant_text_selectable_test.dart test/markdown_table_test.dart`；
4. 真机对比助手正文与用户气泡的选中留白。
