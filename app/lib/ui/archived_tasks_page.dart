import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart';
import 'session_deletion_flow.dart';
import 'settings_style.dart';
import 'task_home.dart';
import 'top_notice.dart';

/// 归档任务浏览页（阶段 3 第三段；2026-11-17 全局化批）：**跨全部
/// 工作区**拉取归档任务——空 scope 调 listArchivedTasks（桌面端
/// listTaskMetas 的 SQL `@workspace_key IS NULL OR` 放行，契约见
/// task_catalog.listArchivedTasksGlobal）。此前只按当前活跃工作区拉，
/// 跨工作区归档的任务（工作区已从桌面移除时）永远查不到——用户实证
/// 两个归档任务恒不显示。每条标注来源工作区；恢复/删除按任务行自身
/// scope 定位。自管加载（不再依赖任务索引快照 app.archivedTasks）。
class ArchivedTasksPage extends StatefulWidget {
  const ArchivedTasksPage({super.key});

  @override
  State<ArchivedTasksPage> createState() => _ArchivedTasksPageState();
}

class _ArchivedTasksPageState extends State<ArchivedTasksPage> {
  bool _busy = false;

  /// null=首载中；非 null=已拉取（含空=真没有归档任务）。
  List<Map<String, dynamic>>? _tasks;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    try {
      final tasks = await app.loadArchivedTasksGlobal();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tasks ??= const [];
        // 异常详情进日志不上屏——动态拼接串过不了 l10n 守卫（英文档

      });
    }
  }

  Future<void> _run(Future<dynamic> Function() action, String okText) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await action();
      if (mounted) {
        TopNotice.show(
          context,
          message: okText,
          icon: Icons.check_circle_outline,
          iconColor: kSettingsIconGreen,
        );
        if (res is Map &&
            res['skippedTaskIds'] is List &&
            (res['skippedTaskIds'] as List).isNotEmpty) {
          TopNotice.show(
            context,
            message: '部分任务已不在归档态，跳过',
            icon: Icons.info_outline,
            iconColor: kSettingsIconOrange,
          );
        }
        await _load(); // 全局批自管：操作后重拉（旧实现靠任务索引快照通知）
      }
    } catch (e) {
      if (mounted) {
        TopNotice.show(
          context,
          message: '操作失败：$e',
          icon: Icons.error_outline,
          iconColor: context.colors.destructive,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> task) async {
    final app = AppStateScope.of(context);
    await _run(
      () => app.unarchiveTaskInScope(task),
      '已恢复「${_titleOf(task)}」',
    );
  }

  Future<void> _deleteOne(Map<String, dynamic> task) async {
    // app 在 await 前取（确认框 await 后用 context 触发跨 async gap lint）。
    final app = AppStateScope.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除这个归档任务？',
      message: '任务将从任务列表和归档列表中移除（官方同款语义，不可恢复）。',
    );
    if (!confirmed) return;
    await _run(
      () => app.deleteArchivedTaskInScope(task),
      '已删除「${_titleOf(task)}」',
    );
  }

  Future<void> _deleteAll(List<Map<String, dynamic>> tasks) async {
    final app = AppStateScope.of(context);
    final confirmed = await showConfirmDialog(
      context,
      title: '删除全部归档任务',
      message: '将删除 ${tasks.length} 个归档任务（不可恢复）。确定继续？',
      confirmLabel: '全部删除',
    );
    if (!confirmed) return;
    // 确认框 await 期间列表可能变化——按现值取删除集（服务端
    // skippedTaskIds 仍兜底"已不在归档态"提示）。
    final current = _tasks ?? tasks;
    await _run(
      () => app.deleteArchivedTasksGlobal(current),
      '已清理 ${current.length} 个归档任务',
    );
  }

  static String _titleOf(Map<String, dynamic> task) {
    final t = '${task['title'] ?? ''}'.trim();
    return t.isEmpty ? '未命名任务' : t;
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('已归档任务'),
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: tr('刷新'),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      // 自管加载（旧实现挂在 app.taskList 快照上，工作区未打开时恒空）。
      body: tasks == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.destructive,
                        ),
                      ),
                    ),
                  if (tasks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 96),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.archive_outlined,
                            size: 40,
                            color: context.colors.foregroundSubtlest,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '没有归档任务',
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              color: context.colors.foregroundSubtle,
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '含全部工作区的归档任务；可恢复或删除',
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.foregroundSubtlest,
                              ),
                            ),
                          ),
                          // 视觉走查②：破坏性批量操作用危险色（审查发现：纯文字
                          // 无警示性、易误触）。
                          TextButton.icon(
                            key: const ValueKey('archive-delete-all'),
                            onPressed: _busy ? null : () => _deleteAll(tasks),
                            icon: Icon(
                              Icons.delete_sweep_outlined,
                              size: 16,
                              color: context.colors.destructive,
                            ),
                            label: Text(
                              '全部删除',
                              style: TextStyle(
                                color: context.colors.destructive,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final t in tasks) _row(context, t),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> t) {
    final updatedAt = (t['updatedAt'] as num?)?.toInt() ?? 0;
    final source = taskRowWorkspaceLabel(t);
    return Container(
      key: ValueKey('archived-task-${t['taskId']}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      child: ListTile(
        title: Text(
          _titleOf(t),
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: AppType.uiBase),
        ),
        subtitle: Text(
          // 来源工作区（全局化批：跨区归档不再"消失"）+ 归档相对时间。
          // pattern 占位不递归 tr——相对时间片段在拼接前先 tr
          //（'3 天前'→'3 days ago'）。
          '来源 $source · ${updatedAt > 0 ? '归档于 ${tr(_relative(updatedAt))}' : '已归档'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppType.uiXs,
            color: context.colors.foregroundSubtlest,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: ValueKey('archive-restore-${t['taskId']}'),
              onPressed: _busy ? null : () => _restore(t),
              // 归档语境的「恢复」是
              // Restore（官方词）；沿用通用键会译成会话语
              // 态的 Resume——换独立键按词典事实修正。
              child: const Text('恢复任务'),
            ),
            IconButton(
              key: ValueKey('archive-delete-${t['taskId']}'),
              onPressed: _busy ? null : () => _deleteOne(t),
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: context.colors.foregroundSubtle,
              ),
            ),
            // ③ 会话永久删除（早前批次）：delete_forever 图标
            // 与普通删除（列表移除）明确区分；点击走 PIN 防呆
            // 三段流（范围预览→PIN→执行）。全局化批：scope=任务行
            // 自身归属（跨区任务此前打偏当前工作区）。
            IconButton(
              key: ValueKey('archive-perm-delete-${t['taskId']}'),
              onPressed: _busy
                  ? null
                  : () => showPermanentDeletionFlow(
                        context,
                        task: t,
                        taskScope: AppStateScope.of(context).taskRowScopeOf(t),
                      ),
              tooltip: tr('永久删除'),
              icon: Icon(
                Icons.delete_forever_outlined,
                size: 18,
                color: context.colors.destructive,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 相对时间收敛到 task_home 单源（原第二份实现不
// 支持注入 now，且与任务中心版本细节漂移）。
String _relative(int millis) => taskHomeRelativeTime(millis);
