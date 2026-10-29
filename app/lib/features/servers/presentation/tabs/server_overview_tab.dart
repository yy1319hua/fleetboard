import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_dot.dart';
import '../../../overview/application/overview_notifier.dart';
import '../../../overview/domain/bootstrap.dart';
import '../../../servers/data/servers_repository.dart';

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

class _ServerOverviewTabState extends ConsumerState<ServerOverviewTab> {
  bool _testing = false;

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
        return RefreshIndicator(
          onRefresh: () => ref.read(overviewProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
            children: [
              _IdentityCard(server: server),
              const SizedBox(height: 12),
              _MetricsCard(metric: metric),
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
          ),
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
                StatusDot(online ? StatusKind.ok : StatusKind.idle),
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
            ? const Color(0xFFB26A00)
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
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
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
