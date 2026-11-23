// 新建目录命令模板：桌面 Windows 终端优先 pwsh/powershell——POSIX
// `mkdir -p --` 无效，按 terminal.create 返回的 shell 平台分流模板。
// PowerShell 分支 2026-11-23 改用 .NET CreateDirectory（New-Item 没有
// -LiteralPath 参数，真机实测报「找不到参数」，此前多轮失败真凶）。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';

void main() {
  test('POSIX shell：mkdir -p 单引号转义', () {
    expect(AppState.buildMkdirCommand('/bin/bash', '项目'), "mkdir -p -- '项目'");
    expect(
      AppState.buildMkdirCommand('/bin/zsh', "a'b"),
      "mkdir -p -- 'a'\\''b'",
    );
  });

  test('PowerShell：命令纯 ASCII（码点组装，绕开控制台编码）', () {
    expect(
      AppState.buildMkdirCommand(
        r'C:\Program Files\PowerShell\7\pwsh.exe',
        '项目',
      ),
      '[System.IO.Directory]::CreateDirectory('
      '(-join @(0x9879,0x76ee | ForEach-Object { [char]\$_ }))) | Out-Null',
    );
    // 纯 ASCII 名（含单引号）走单引号字符串、内部 ' → ''。
    expect(
      AppState.buildMkdirCommand('powershell.exe', "a'b"),
      "[System.IO.Directory]::CreateDirectory('a''b') | Out-Null",
    );
    // 断言整条命令无可打印非 ASCII 字符。
    final ascii = AppState.buildMkdirCommand('pwsh.exe', '中文测试');
    expect(ascii.runes.every((r) => r < 128), isTrue);
  });

  test('cmd：切 UTF-8 后 mkdir', () {
    expect(
      AppState.buildMkdirCommand(r'C:\Windows\System32\cmd.exe', '项目'),
      'chcp 65001 >nul & mkdir "项目"',
    );
  });
}
