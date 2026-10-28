import 'package:flutter/material.dart' hide Container;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/status_dot.dart';
import '../application/containers_notifier.dart';
import '../domain/container.dart';
import 'container_actions_sheet.dart';
import 'container_logs_page.dart';

/// 容器状态 -> 语义色（对齐 DESIGN.md 状态色，仅表达状态）。
StatusKind _kindFromState(String state) => switch (state) {
      'running' => StatusKind.ok,
      'paused' => StatusKind.warn,
      'created' => StatusKind.info,
      'exited' => StatusKind.idle,
      _ => StatusKind.idle,
    };

/// 容器列表页（M9.3）：消费 GET /api/servers/:serverId/containers。
/// 点按容器打开操作弹层（启停/重启/删）；右侧图标进入实时日志。
class ContainersPage extends ConsumerWidget {
  const ContainersPage({super.key, required this.serverId});
  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? sid = int.tryParse(serverId);
    if (sid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('容器')),
        body: const Center(child: Text('无效 serverId')),
      );
    }
    final state = ref.watch(containersProvider(sid));
    return Scaffold(
      appBar: AppBar(title: const Text('容器')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败：$e'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () =>
                    ref.read(containersProvider(sid).notifier).load(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('无容器'));
          }
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(containersProvider(sid).notifier).refresh(),
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = list[i];
                return ListTile(
                  leading: StatusDot(_kindFromState(c.state)),
                  title: Text(c.name.isEmpty ? c.id : c.name),
                  subtitle: Text(
                    c.ports.isEmpty
                        ? '${c.image} · ${c.status}'
                        : '${c.image} · ${c.status} · ${c.ports}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.article_outlined),
                    tooltip: '实时日志',
                    onPressed: () => _openLogs(context, sid, c),
                  ),
                  onTap: () => _openActions(context, sid, c),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _openActions(BuildContext context, int sid, Container c) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ContainerActionsSheet(serverId: sid, container: c),
    );
  }

  Future<void> _openLogs(BuildContext context, int sid, Container c) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ContainerLogsPage(serverId: sid, container: c),
      ),
    );
  }
}
