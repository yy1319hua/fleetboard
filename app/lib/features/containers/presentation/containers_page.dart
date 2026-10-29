import 'package:flutter/material.dart';

import 'container_list_view.dart';

/// 容器列表独立路由页（深链兜底）。
///
/// 正常路径是从服务器详情页的「容器」Tab 进入（同一台仪器的上下文里），
/// 这个全屏页保留给「已持有 /servers/:id/containers 链接」与测试场景。
/// 主体与 Tab 共用 [ContainerListView]，不存在两套行为。
class ContainersPage extends StatelessWidget {
  const ContainersPage({super.key, required this.serverId});
  final String serverId;

  @override
  Widget build(BuildContext context) {
    final sid = int.tryParse(serverId);
    return Scaffold(
      appBar: AppBar(title: const Text('容器')),
      body: sid == null
          ? const Center(child: Text('服务器编号无效，请返回重试'))
          : ContainerListView(serverId: sid),
    );
  }
}
