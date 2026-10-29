import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/widgets/hold_to_confirm.dart';
import '../../../overview/application/overview_notifier.dart';
import '../../../servers/data/servers_repository.dart';

/// 服务器详情 · 运维段。
///
/// 放「对这台机器动手」的入口：包更新、Compose 编排、以及删除纳管。
/// 删除放在最底部且必须长按——它是这段里唯一不可撤销的操作。
class ServerOpsTab extends ConsumerWidget {
  const ServerOpsTab({super.key, required this.serverId});
  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final servers = ref.watch(overviewProvider).value?.servers ?? const [];
    final server = servers.where((s) => s.id == serverId).firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
      children: [
        _ActionTile(
          icon: Icons.system_update_alt_outlined,
          title: '包更新',
          subtitle: '执行 apt 升级，后台任务可续接、可取消',
          onTap: () => context.go('/servers/$serverId/update'),
        ),
        _ActionTile(
          icon: Icons.account_tree_outlined,
          title: 'Compose 编排',
          subtitle: '查看 compose 文件、就地改服务、执行起停',
          onTap: () => context.push('/servers/$serverId/compose'),
        ),
        _ActionTile(
          icon: Icons.inventory_2_outlined,
          title: '资源',
          subtitle: '镜像 / 网络 / 卷',
          onTap: () => context.push('/servers/$serverId/resources'),
        ),
        const Divider(height: 32),
        Text('服务器信息', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (server == null)
          Text(
            '这台服务器已不在纳管列表中。',
            style: theme.textTheme.bodySmall,
          )
        else ...[
          _kv(theme, '服务器编号', '#${server.id}'),
          _kv(theme, '纳管时间', _fmt(server.createdAt)),
          _kv(theme, '地址', '${server.host}:${server.port}'),
        ],
        const Divider(height: 32),
        Text(
          '危险操作',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '删除纳管只是把服务器从面板里移除，不会动目标机器上的任何东西；'
          '但面板从此无法再连接它，需要重新填写凭据才能加回来。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        HoldToConfirm(
          label: '按住 1.5 秒删除这台服务器',
          icon: Icons.delete_outline,
          onConfirmed: () => _confirmDelete(context, ref),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    // 长按已经过滤掉误触，这里再确认一次是因为「删除纳管」在用户心智里
    // 很容易和「卸载软件」混淆，值得多说一句。
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除纳管？'),
        content: const Text('目标机器不受影响，但面板将无法再连接它。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(serversRepositoryProvider).remove(serverId);
      await ref.read(overviewProvider.notifier).refresh();
      // 只刷新列表，不要把用户从详情页弹回总览——他可能还想看别的机器。
      // 但当前这台已经不存在，继续停留没有意义，所以退回上一级。
      if (router.canPop()) {
        router.pop();
      } else {
        router.go('/overview');
      }
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeApiError(e))));
    }
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(
                k,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: Text(v, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
