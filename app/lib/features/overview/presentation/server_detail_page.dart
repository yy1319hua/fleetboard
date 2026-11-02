import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/server_tabs.dart';
import '../../../core/widgets/status_dot.dart';
import '../../overview/application/overview_notifier.dart';

/// 服务器详情页：五段 Tab（概览 / 容器 / 监控 / 文件 / 运维）。
///
/// 取代 M9.1 的两行 ListTile 占位实现：五段各自接真实数据源，
/// 每段都有空态与错误态文案（空态必须说明「为什么空、怎么让它不空」）。
///
/// Tab 状态与 URL 联动：`/servers/3?tab=文件` 可直达指定段（App 内部导航用得上，
/// 例如从通知中心点「磁盘告警」直接落到监控段）。**只改 query 不改路径**，
/// 这样返回栈仍只有一层详情页。
class ServerDetailPage extends ConsumerStatefulWidget {
  const ServerDetailPage({
    super.key,
    required this.serverId,
    this.initialTab,
  });

  final String serverId;
  final String? initialTab;

  @override
  ConsumerState<ServerDetailPage> createState() => _ServerDetailPageState();
}

class _ServerDetailPageState extends ConsumerState<ServerDetailPage>
    with SingleTickerProviderStateMixin {
  late final TabController _controller = TabController(
    length: serverTabs.length,
    vsync: this,
    initialIndex: serverTabIndex(widget.initialTab),
  )..addListener(_handleTabChanged);

  /// 当前段索引。只为「监控段要不要允许横滑切段」这一件事维护：
  /// TabController.index 在 animateTo 开始时就已变成目标值，所以监听器里
  /// 必须自己比一次，否则每帧动画都会 setState。
  late int _tabIndex = _controller.index;

  void _handleTabChanged() {
    if (_tabIndex == _controller.index) return;
    setState(() => _tabIndex = _controller.index);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sid = int.tryParse(widget.serverId);
    if (sid == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('服务器')),
        body: const Center(child: Text('服务器编号无效，请返回重试')),
      );
    }
    final servers = ref.watch(overviewProvider).value?.servers ?? const [];
    final server = servers.where((s) => s.id == sid).firstOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (server != null) ...[
              StatusDot(
                server.connectionStatus == 'online'
                    ? StatusKind.ok
                    : StatusKind.idle,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                server?.name ?? '服务器 #$sid',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (server != null)
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final saved = await context.push<bool>(
                  '/settings/servers/edit/${server.id}',
                  extra: server,
                );
                if (saved == true) {
                  ref.read(overviewProvider.notifier).refresh();
                }
              },
            ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(overviewProvider.notifier).refresh(),
          ),
        ],
        bottom: TabBar(
          controller: _controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: theme.textTheme.labelLarge,
          tabs: [
            for (final tab in serverTabs)
              Tab(
                height: 44,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(tab.icon, size: 16),
                    const SizedBox(width: 6),
                    Text(tab.label),
                  ],
                ),
              ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _controller,
        // 监控段禁止横滑切段：那一段里左右拖动是「移动时间游标」，
        // 段级横滑会和它抢同一个手势。与其在竞技场里赌谁先 accept
        // （v0.4.10 试过，真机上外层照样赢），不如从结构上让外层不参战。
        // 代价：监控段不能用滑动切段，要点上面的 Tab —— 仪表盘类页面的常规做法。
        physics: _tabIndex == serverTabIndex('监控')
            ? const NeverScrollableScrollPhysics()
            : null,
        children: [
          for (final tab in serverTabs)
            // KeepAlive 让来回切 Tab 不重拉数据；离开详情页后 provider 的
            // autoDispose 才会真正释放轮询，两者不冲突。
            _KeepAlive(child: tab.builder(sid)),
        ],
      ),
      floatingActionButton: server == null
          ? null
          : FloatingActionButton.small(
              tooltip: '容器日志',
              onPressed: () =>
                  context.go('/servers/${widget.serverId}/containers'),
              child: const Icon(Icons.article_outlined),
            ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
