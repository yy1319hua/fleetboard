import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/server_tabs.dart';
import '../../../core/widgets/status_dot.dart';
import '../../../core/widgets/tab_active_scope.dart';
import '../../../core/widgets/tab_refresh_scope.dart';
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

  /// 每个分段一个刷新句柄，由分段自己注册（见 TabRefreshScope）。
  ///
  /// 为什么不让父级直接调各 provider：监控段的时间窗、文件段的当前目录都是
  /// 分段内部状态，父级根本不知道要传什么参数。句柄是唯一不需要父级偷看子级
  /// 状态的接法。
  late final List<TabRefreshSlot> _slots = List.generate(
    serverTabs.length,
    (_) => TabRefreshSlot(),
  );

  /// AppBar 刷新按钮：刷「当前这一段」。
  ///
  /// 没注册句柄的分段（运维段没有可刷新的列表）退回刷新概览——按钮按下去
  /// 总要有反馈，不能出现「点了什么都不发生」的情况。
  Future<void> _refreshCurrentTab() async {
    final slot = _slots[_tabIndex];
    if (slot.hasHandler) {
      await slot.run();
      return;
    }
    await ref.read(overviewProvider.notifier).refresh();
  }

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
            tooltip: '刷新当前分段',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshCurrentTab,
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
          for (var i = 0; i < serverTabs.length; i++)
            // 子树始终保留（切回来不重拉、滚动位置不丢），可见性单独下传：
            // 各段据此停掉自己的轮询。两者拆开之后，既没有「切走还在打 SSH」，
            // 也没有「切回来从头加载」。
            _KeepAlive(
              active: _tabIndex == i,
              child: TabRefreshScope(
                slot: _slots[i],
                child: serverTabs[i].builder(sid),
              ),
            ),
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
  const _KeepAlive({required this.child, this.active = true});
  final Widget child;

  /// 该段当前是否可见；仅用于向下传递，不影响子树是否构建。
  final bool active;

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
    // 注意：即使 !active 也不返回占位。销毁子树会丢掉滚动位置与已加载的数据，
    // 用户切回来看到从头加载的空白列表——比多跑两条定时器更糟。
    // 停轮询交给 TabActiveScope 的接收方自己处理。
    return TabActiveScope(active: widget.active, child: widget.child);
  }
}
