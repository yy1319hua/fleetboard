import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/hold_to_confirm.dart';
import '../../../core/widgets/status_dot.dart';
import '../../overview/domain/bootstrap.dart';
import '../../servers/application/servers_provider.dart';
import '../application/alert_rules_notifier.dart';
import '../domain/alert_rule.dart';
import 'alert_rule_edit_page.dart';

/// 告警规则管理（列表 + 开关 + 新建/编辑/删除）。
///
/// 页面顶部写清两条用户一定会踩到的语义（都来自后端实现，不是猜测）：
///  1. **没有"持续 N 分钟"**：每采集一次就评估一次，超阈值就写一条通知，
///     没有静默窗口/去重。所以阈值别设太贴（比如 CPU > 60 会每分钟一条）。
///  2. **应用内通知关不掉**：`notify_channels` 只控制 PushPlus。
class AlertRulesPage extends ConsumerWidget {
  const AlertRulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(alertRulesProvider);
    final notifier = ref.read(alertRulesProvider.notifier);
    // 服务器名只为把 "服务器 #3" 变成 "web-01（#3）"；拿不到就退回显示 ID。
    final serverList = ref.watch(serversProvider).valueOrNull ?? <Server>[];
    final serverNames = <int, String>{
      for (final server in serverList) server.id: server.name,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('告警规则'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: notifier.load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add_alert_outlined),
        label: const Text('新建规则'),
      ),
      body: Column(
        children: [
          const _RuleSemanticsNotice(),
          Expanded(
            child: AsyncStateView<List<AlertRule>>(
              value: state,
              loadingHint: '正在读取规则…',
              onRetry: notifier.load,
              emptyHint: '还没有告警规则。点右下角「新建规则」建第一条：'
                  '最常用的是「CPU 使用率 > 80%」，命中后会出现在通知中心，'
                  '需要电话/微信提醒再打开 PushPlus。',
              builder: (rules) => RefreshIndicator(
                onRefresh: notifier.refresh,
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: rules.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final rule = rules[index];
                    return _RuleTile(
                      rule: rule,
                      scopeName: rule.serverId == null
                          ? '全局'
                          : (serverNames[rule.serverId] ?? '服务器 #${rule.serverId}'),
                      onToggle: (enabled) =>
                          _toggle(context, notifier, rule, enabled),
                      onEdit: () => _openEditor(context, rule: rule),
                      onDelete: () => _confirmDelete(context, ref, rule),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 打开编辑页。保存成功后列表由 notifier 就地更新，这里不需要再拉一次。
  Future<void> _openEditor(BuildContext context, {AlertRule? rule}) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AlertRuleEditPage(rule: rule),
      ),
    );
  }

  /// 开关：直接 PUT（merge，只发 enabled），失败由 notifier 回滚并在此提示。
  Future<void> _toggle(
    BuildContext context,
    AlertRulesNotifier notifier,
    AlertRule rule,
    bool enabled,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await notifier.toggle(rule, enabled);
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('切换失败，已恢复原状态：${describeApiError(e)}'),
        ),
      );
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AlertRule rule,
  ) async {
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _DeleteRuleSheet(rule: rule),
    );
    if (deleted != true) return;
    try {
      await ref.read(alertRulesProvider.notifier).remove(rule);
    } on Object catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：${describeApiError(e)}')),
      );
    }
  }
}

class _RuleSemanticsNotice extends StatelessWidget {
  const _RuleSemanticsNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        '后端按每次采集（约每分钟）评估一次：超阈值就写一条通知，'
        '没有「持续 N 分钟」也没有静默窗口，所以阈值别设太贴。'
        '应用内通知恒定开启，PushPlus 需在设置里配 token。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.scopeName,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final AlertRule rule;
  final String scopeName;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: StatusDot(alertSeverityKind(rule.severity)),
      title: Text(
        rule.title,
        style: TextStyle(
          // 停用的规则压暗：列表里一眼能分出"哪些在生效"。
          color: rule.enabled ? null : theme.colorScheme.outline,
        ),
      ),
      subtitle: Text(
        '$scopeName · ${alertSeverityLabel(rule.severity)} · ${rule.channelLabel}'
        '${rule.enabled ? '' : ' · 已停用'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Switch(
        value: rule.enabled,
        onChanged: onToggle,
      ),
      onTap: onEdit,
      // 长按删除：规则删掉就没有了，长按能拦住手滑。
      onLongPress: onDelete,
    );
  }
}

/// 删除规则确认层。
///
/// 只负责「确认」，不负责请求：真正的 DELETE 由列表页执行（它要更新列表并提示错误）。
class _DeleteRuleSheet extends StatelessWidget {
  const _DeleteRuleSheet({required this.rule});

  final AlertRule rule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('删除告警规则', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(rule.title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Text(
            '规则 #${rule.id} · ${rule.scopeLabel}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text(
            '删除后不可恢复；已经产生的通知不会被删除。'
            '如果只是想暂时停用，回到列表把开关关掉即可。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          HoldToConfirm(
            label: '按住 1.5 秒删除规则',
            icon: Icons.delete_outline,
            onConfirmed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}
