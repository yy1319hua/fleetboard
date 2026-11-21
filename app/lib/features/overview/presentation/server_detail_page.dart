import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/server_tabs.dart';
import '../../../core/widgets/refresh_icon_button.dart';
import '../../../core/widgets/status_dot.dart';
import '../../../core/widgets/tab_active_scope.dart';
import '../../../core/widgets/tab_refresh_scope.dart';
import '../../overview/application/overview_notifier.dart';
import '../../servers/data/facts_repository.dart';

/// 服务器详情页：分段随机器能力变化（概览 / 容器 / 监控 / 文件 / 运维）。
///
/// 分段不再固定五个：首次保存时体检测出「没有 Docker」「没有 sftp 子系统」，
/// 对应的段直接不出现——留着点了只会报错的入口，比没有更让人困惑。
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
  TabController? _controller;

  /// 当前实际显示的分段。首帧按全量渲染，facts 到达后再收窄。
  List<ServerTabSpec> _tabs = serverTabs;

  /// 刷新句柄按 label 存，不按索引：分段数量会随能力变化而变，
  /// 用索引存会在重建时把「文件段的句柄」错配给「监控段」。
  final Map<String, TabRefreshSlot> _slots = <String, TabRefreshSlot>{};

  /// 当前段索引。只为「监控段要不要允许横滑切段」这一件事维护：
  /// TabController.index 在 animateTo 开始时就已变成目标值，所以监听器里
  /// 必须自己比一次，否则每帧动画都会 setState。
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _installController(serverTabs, widget.initialTab);
  }

  TabRefreshSlot _slotFor(String label) =>
      _slots.putIfAbsent(label, TabRefreshSlot.new);

  void _installController(List<ServerTabSpec> tabs, String? keepLabel) {
    final labels = tabs.map((t) => t.label).toList(growable: false);
    var idx = keepLabel == null ? 0 : labels.indexOf(keepLabel);
    if (idx < 0) idx = 0;

    _controller?.removeListener(_handleTabChanged);
    _controller?.dispose();
    _controller = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: idx,
    )..addListener(_handleTabChanged);
    _tabs = tabs;
    _tabIndex = idx;
  }

  bool _sameLabels(List<ServerTabSpec> a, List<ServerTabSpec> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].label != b[i].label) return false;
    }
    return true;
  }

  /// AppBar 刷新按钮：刷「当前这一段」。
  ///
  /// 没注册句柄的分段（运维段没有可刷新的列表）退回刷新概览——按钮按下去
  /// 总要有反馈，不能出现「点了什么都不发生」的情况。
  Future<void> _refreshCurrentTab() async {
    final slot = _tabIndex < _tabs.length
        ? _slotFor(_tabs[_tabIndex].label)
        : null;
    if (slot != null && slot.hasHandler) {
      await slot.run();
      return;
    }
    await ref.read(overviewProvider.notifier).refresh();
  }

  void _handleTabChanged() {
    final c = _controller;
    if (c == null || _tabIndex == c.index) return;
    setState(() => _tabIndex = c.index);
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleTabChanged);
    _controller?.dispose();
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

    // 能力来自首次保存时的体检结果。-1（没探到）时两段都保留。
    final facts = ref.watch(serverFactsProvider(sid)).valueOrNull;
    final nextTabs = visibleServerTabs(
      hasDocker: facts?.hasDocker ?? -1,
      hasSftp: facts?.hasSftp ?? -1,
    );
    if (!_sameLabels(_tabs, nextTabs)) {
      // 不能在 build 里 dispose 正在被 TabBar 使用的 controller（会抛
      // "used after being disposed"），所以推到帧末再重建。
      // 代价是收窄分段时会闪一帧，只发生在 facts 首次加载完成那一刻。
      final keep = _tabIndex < _tabs.length ? _tabs[_tabIndex].label : widget.initialTab;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_sameLabels(_tabs, nextTabs)) return;
        setState(() => _installController(nextTabs, keep));
      });
    }

    final controller = _controller;
    final tabs = _tabs;
    final monitorIndex = tabIndexOf(tabs, '监控');

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            if (server != null) ...[
              StatusLabel(
                kind: server.monitorEnabled &&
                        server.connectionStatus == 'online'
                    ? StatusKind.ok
                    : StatusKind.idle,
                // 「仅保存」从不被轮询，unknown 会被读成掉线。
                label: server.monitorEnabled
                    ? connectionStatusLabel(server.connectionStatus)
                    : '未监控',
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
          RefreshIconButton(
            tooltip: '刷新当前分段',
            onRefresh: _refreshCurrentTab,
          ),
        ],
        bottom: controller == null
            ? null
            : TabBar(
                controller: controller,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelStyle: theme.textTheme.labelLarge,
                tabs: [
                  for (final tab in tabs)
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
      body: controller == null
          ? const SizedBox.shrink()
          : TabBarView(
              controller: controller,
              // 监控段禁止横滑切段：那一段里左右拖动是「移动时间游标」，
              // 段级横滑会和它抢同一个手势。与其在竞技场里赌谁先 accept
              // （v0.4.10 试过，真机上外层照样赢），不如从结构上让外层不参战。
              // 代价：监控段不能用滑动切段，要点上面的 Tab —— 仪表盘类页面的常规做法。
              physics: _tabIndex == monitorIndex
                  ? const NeverScrollableScrollPhysics()
                  : null,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  // 子树始终保留（切回来不重拉、滚动位置不丢），可见性单独下传：
                  // 各段据此停掉自己的轮询。两者拆开之后，既没有「切走还在打 SSH」，
                  // 也没有「切回来从头加载」。
                  _KeepAlive(
                    active: _tabIndex == i,
                    child: TabRefreshScope(
                      slot: _slotFor(tabs[i].label),
                      child: tabs[i].builder(sid),
                    ),
                  ),
              ],
            ),
      floatingActionButton: server == null || !tabs.any((t) => t.label == '容器')
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
