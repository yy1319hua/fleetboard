import 'package:flutter/material.dart' hide Container;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_dot.dart';
import '../application/containers_notifier.dart';
import '../domain/container.dart';
import 'container_actions_sheet.dart';
import 'container_logs_page.dart';

/// 容器状态 -> 语义色（对齐 DESIGN.md 状态色，仅表达状态）。
StatusKind statusKindFromState(String state) => switch (state) {
      'running' => StatusKind.ok,
      'paused' => StatusKind.warn,
      'created' => StatusKind.info,
      'exited' => StatusKind.idle,
      _ => StatusKind.idle,
    };

/// 容器列表视图（不含 Scaffold）。
///
/// 从 [ContainersPage] 抽出，是因为详情页把它作为五个 Tab 之一内嵌——
/// 如果 Tab 里再套一个 Scaffold，会出现双层 AppBar，且 Tab 切换时
/// 底部导航栏高度会被算两遍。独立全屏路由仍复用本视图，保证两处行为一致。
class ContainerListView extends ConsumerWidget {
  const ContainerListView({super.key, required this.serverId});

  final int serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(containersProvider(serverId));
    return AsyncStateView<List<Container>>(
      value: state,
      emptyHint: '这台服务器上还没有容器。若你刚部署了服务，稍等几秒后下拉刷新。',
      onRetry: () => ref.read(containersProvider(serverId).notifier).load(),
      builder: (list) => RefreshIndicator(
        onRefresh: () => ref.read(containersProvider(serverId).notifier).refresh(),
        child: ListView.separated(
          // 容器多时列表要能滚到底：底部留出 FAB 与导航栏的高度。
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final c = list[i];
            return ListTile(
              leading: StatusDot(statusKindFromState(c.state)),
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
                onPressed: () => openContainerLogs(context, serverId, c),
              ),
              onTap: () => openContainerActions(context, serverId, c),
            );
          },
        ),
      ),
    );
  }
}

/// 打开容器操作弹层（启停/重启/删除）。
Future<void> openContainerActions(
  BuildContext context,
  int serverId,
  Container container,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => ContainerActionsSheet(serverId: serverId, container: container),
  );
}

/// 打开实时日志页。
Future<void> openContainerLogs(
  BuildContext context,
  int serverId,
  Container container,
) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ContainerLogsPage(serverId: serverId, container: container),
    ),
  );
}
