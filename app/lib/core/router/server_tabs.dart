import 'package:flutter/material.dart';

import '../../features/containers/presentation/container_list_view.dart';
import '../../features/files/presentation/server_files_tab.dart';
import '../../features/monitor/presentation/server_monitor_tab.dart';
import '../../features/servers/presentation/tabs/server_ops_tab.dart';
import '../../features/servers/presentation/tabs/server_overview_tab.dart';

/// 服务器详情页的一个分段（Tab）。
///
/// 为什么用一张表驱动，而不是在详情页里手写五个 Tab 和五个 TabBarView 子项：
/// 手写时「Tab 数量」「TabBarView 子项数量」「TabController 长度」三处必须同步，
/// 改一处忘了另外两处，运行期直接抛 `Controller's length property does not match`，
/// 而这种错误在 CI 的 widget 测试里未必覆盖得到。表驱动只剩一个真值源。
///
/// 分段顺序即产品优先级：概览 → 容器 → 监控 → 文件 → 运维。
/// 「容器」排第二是因为它是应急场景里最常用的（服务挂了先看容器在不在）。
class ServerTabSpec {
  const ServerTabSpec({
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String label;
  final IconData icon;
  final Widget Function(int serverId) builder;
}

Widget _overview(int id) => ServerOverviewTab(serverId: id);
Widget _containers(int id) => ContainerListView(serverId: id);
Widget _monitor(int id) => ServerMonitorTab(serverId: id);
Widget _files(int id) => ServerFilesTab(serverId: id);
Widget _ops(int id) => ServerOpsTab(serverId: id);

const List<ServerTabSpec> serverTabs = <ServerTabSpec>[
  ServerTabSpec(label: '概览', icon: Icons.speed_outlined, builder: _overview),
  ServerTabSpec(
    label: '容器',
    icon: Icons.view_list_outlined,
    builder: _containers,
  ),
  ServerTabSpec(
    label: '监控',
    icon: Icons.show_chart_outlined,
    builder: _monitor,
  ),
  ServerTabSpec(
    label: '文件',
    icon: Icons.folder_outlined,
    builder: _files,
  ),
  ServerTabSpec(
    label: '运维',
    icon: Icons.build_outlined,
    builder: _ops,
  ),
];

/// 按 label 找索引（深链 `?tab=文件` 用）。
int serverTabIndex(String? label) {
  if (label == null || label.isEmpty) return 0;
  final i = serverTabs.indexWhere((t) => t.label == label);
  return i < 0 ? 0 : i;
}
