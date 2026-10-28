import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 服务器详情页（M9.1 路由占位；M9.3/M9.4 逐步填充）。
///
/// 提供「容器」（M9.3）与「包更新」（M9.4）入口，后续补充概览分段。
class ServerDetailPage extends ConsumerWidget {
  const ServerDetailPage({super.key, required this.serverId});
  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text('服务器 #$serverId'),
            subtitle: const Text('M9.3/M9.4 逐步填充概览/容器/包'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.view_list_outlined),
            title: const Text('容器'),
            subtitle: const Text('查看与操作容器'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/servers/$serverId/containers'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt_outlined),
            title: const Text('包更新'),
            subtitle: const Text('apt 升级（后台任务，可续接/取消）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/servers/$serverId/update'),
          ),
        ],
      ),
    );
  }
}
