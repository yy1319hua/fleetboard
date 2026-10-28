import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/status_dot.dart';
import '../application/containers_notifier.dart';
import '../domain/container.dart';

/// 容器状态 -> 语义色（对齐 DESIGN.md 状态色，仅表达状态）。
StatusKind _kindFromState(String state) => switch (state) {
      'running' => StatusKind.ok,
      'paused' => StatusKind.warn,
      'created' => StatusKind.info,
      'exited' => StatusKind.idle,
      _ => StatusKind.idle,
    };

/// 容器列表页（M9.3 步1）：消费 GET /api/servers/:serverId/containers。
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
                  subtitle: Text('${c.image} · ${c.status}'),
                  trailing: c.ports.isNotEmpty
                      ? Text(
                          c.ports,
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : null,
                );
              },
            ),
          );
        },
      ),
    );
  }
}
