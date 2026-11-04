import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_dot.dart';
import '../../../../core/widgets/tab_refresh_scope.dart';
import '../../../overview/application/overview_notifier.dart';
import '../../../overview/domain/bootstrap.dart';
import '../../../servers/data/servers_repository.dart';
import '../../data/facts_repository.dart';
import '../../domain/server_facts.dart';

/// 服务器详情 · 概览段。
///
/// 这一段的定位是「一眼判断这台机器现在怎么样」，所以只放三类东西：
/// 身份（是哪台）、健康（连接 + 四项指标）、下一步动作（测试连接 / 包更新）。
/// 不放任何需要滚动很久才能看完的日志或列表——那些在各自的功能段里。
class ServerOverviewTab extends ConsumerStatefulWidget {
  const ServerOverviewTab({super.key, required this.serverId});
  final int serverId;

  @override
  ConsumerState<ServerOverviewTab> createState() => _ServerOverviewTabState();
}

class _ServerOverviewTabState extends ConsumerState<ServerOverviewTab>
    with TabRefreshBinding<ServerOverviewTab> {
  bool _testing = false;

  /// 本段的刷新：总览（身份 + 实时指标）重拉一次，系统配置重读一次。
  ///
  /// 系统配置由后台按小时采集，重读不会产生新的 SSH 采集，只是把「上次采集到
  /// 的配置」重新取回来——但用户按了刷新却看到那一行纹丝不动会以为按钮坏了，
  /// 所以这里显式失效一次，让时间戳和数据都走一遍网络。
  @override
  Future<void> refreshTab() async {
    await ref.read(overviewProvider.notifier).refresh();
    if (!mounted) return;
    ref.invalidate(serverFactsProvider(widget.serverId));
  }

  Future<void> _testConnection(Server server) async {
    setState(() => _testing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final status = await ref.read(serversRepositoryProvider).test(server.id);
      if (!mounted) return;
      // 服务端会把结果落库（connection_status），刷新总览才能让卡片上的点变色。
      await ref.read(overviewProvider.notifier).refresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text(status == 'online' ? '连接正常' : '连接失败：$status'),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(describeApiError(e))));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(overviewProvider);
    return AsyncStateView<BootstrapResponse>(
      value: state,
      emptyHint: '这台服务器已不在纳管列表中，可能已在 Web 端被删除。',
      isEmpty: (data) => !data.servers.any((s) => s.id == widget.serverId),
      onRetry: () => ref.read(overviewProvider.notifier).load(),
      builder: (data) {
        final server = data.servers.firstWhere((s) => s.id == widget.serverId);
        final metric = data.metrics['${widget.serverId}'];
        // 刷新入口统一收到 AppBar 按钮（本段通过 TabRefreshScope 注册了
        // refreshTab）：这里不再套 RefreshIndicator，两个入口做同一件事，
        // 反而让人以为刷的不是一份数据。
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          children: [
            _IdentityCard(server: server),
            const SizedBox(height: 12),
            _MetricsCard(metric: metric),
            const SizedBox(height: 12),
            _FactsCard(state: ref.watch(serverFactsProvider(widget.serverId))),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _testing ? null : () => _testConnection(server),
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cable_outlined, size: 18),
              label: Text(_testing ? '正在测试连接…' : '测试 SSH 连接'),
            ),
            const SizedBox(height: 8),
            Text(
              '连接测试会真实拨号 SSH，用于确认凭据是否仍然有效；'
              '结果同时写回连接状态。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.server});
  final Server server;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = server.connectionStatus == 'online';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(
                  online ? StatusKind.ok : StatusKind.idle,
                  semanticLabel: online ? '在线' : '未知',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    server.name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  online ? '在线' : '离线',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: online
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv(theme, '地址', '${server.host}:${server.port}'),
            _kv(theme, '登录用户', server.sshUser),
            _kv(
              theme,
              '认证方式',
              server.authMethod == 'key' ? 'SSH 私钥' : '密码',
            ),
            if (server.tags.isNotEmpty) _kv(theme, '标签', server.tags),
            _kv(
              theme,
              '最近心跳',
              server.lastHeartbeat == null
                  ? '暂无'
                  : _relative(server.lastHeartbeat!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
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

  static String _relative(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({required this.metric});
  final MetricLatest? metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = metric;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('实时指标', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text(
                  m == null ? '暂无数据' : '${_ago(m.ts)}采样',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (m == null)
              Text(
                '还没有采集到指标。面板默认每分钟采样一次，首次纳管后约一分钟出现。',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              _bar(theme, 'CPU', m.cpuPct),
              _bar(theme, '内存', m.memPct),
              _bar(theme, '磁盘', m.diskPct),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _plain(theme, '负载', m.load1.toStringAsFixed(2)),
                  ),
                  Expanded(
                    child: _plain(
                      theme,
                      '下行',
                      '${m.netInKbps.toStringAsFixed(0)} KB/s',
                    ),
                  ),
                  Expanded(
                    child: _plain(
                      theme,
                      '上行',
                      '${m.netOutKbps.toStringAsFixed(0)} KB/s',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    return '${d.inHours} 小时前';
  }

  Widget _bar(ThemeData theme, String label, double pct) {
    // 阈值沿用后端告警默认值思路：80% 起黄、90% 起红。
    final color = pct >= 90
        ? theme.colorScheme.error
        : pct >= 80
            ? AppColors.warn
            : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _plain(ThemeData theme, String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      );
}

/// 系统配置卡：这台机器是什么样（CPU 型号/核数、内存总量、磁盘挂载点、系统与内核）。
///
/// 数据来自后台每小时一次的采集，与「实时指标」是两条独立链路：指标挂了
/// （SSH 抖动）不影响这里显示上一次的配置；配置没采到也不影响指标的刷新。
class _FactsCard extends StatelessWidget {
  const _FactsCard({required this.state});

  final AsyncValue<ServerFacts?> state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = state.valueOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('系统配置', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (facts != null)
                  Text(
                    '${_ago(facts.collectedAt)}采集',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (state.isLoading)
              const LinearProgressIndicator(minHeight: 3)
            else if (state.hasError)
              Text(
                '读取配置失败：${describeApiError(state.error!)}',
                style: theme.textTheme.bodySmall,
              )
            else if (facts == null)
              Text(
                '尚未采集到配置。后台每小时采集一次，服务器离线或刚纳管时暂无数据。',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              _kv(theme, 'CPU', facts.cpuModel.isEmpty ? '—' : facts.cpuModel),
              if (facts.cpuCores > 0) _kv(theme, '线程数', '${facts.cpuCores}'),
              _kv(
                theme,
                '内存',
                facts.swapTotalKb > 0
                    ? '${facts.memTotalText}（Swap ${facts.swapTotalText}）'
                    : facts.memTotalText,
              ),
              _kv(theme, '系统', facts.osName.isEmpty ? '—' : facts.osName),
              _kv(theme, '内核', facts.kernel.isEmpty ? '—' : facts.kernel),
              _kv(theme, '架构', facts.arch.isEmpty ? '—' : facts.arch),
              _kv(theme, '虚拟化', facts.virtLabel),
              _kv(theme, '主机名', facts.hostname.isEmpty ? '—' : facts.hostname),
              _kv(theme, '运行时长', facts.uptimeText),
              if (facts.disks.isNotEmpty) ...[
                const Divider(height: 20),
                Text(
                  '磁盘',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                for (final d in facts.disks) _disk(theme, d),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
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

  /// 一个挂载点：挂载路径 + 已用/总量 + 占比条（阈值与实时指标一致）。
  Widget _disk(ThemeData theme, DiskUsage d) {
    final pct = d.usedPct.clamp(0.0, 100.0);
    final color = pct >= 90
        ? theme.colorScheme.error
        : pct >= 80
            ? AppColors.warn
            : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d.mount.isEmpty
                      ? (d.device.isEmpty ? '—' : d.device)
                      : d.mount,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${d.usedText} / ${d.totalText}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }
}
