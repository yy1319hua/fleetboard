import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_dot.dart';
import '../domain/bootstrap.dart';

/// 服务器卡片：名称 + 在线状态 + 主机 + 最新指标摘要（CPU/内存/磁盘）。
class ServerCard extends StatelessWidget {
  const ServerCard({
    super.key,
    required this.server,
    this.metric,
    this.onTap,
  });

  final Server server;
  final MetricLatest? metric;

  /// 点击行为。默认进入该服务器详情；需要别的行为时由调用处覆盖。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      // 让水波纹被圆角裁掉，否则深色底上会露出方角
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap ?? () => context.go('/servers/${server.id}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  StatusDot(statusFromConnection(server.connectionStatus)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      server.name,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: AppColors.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    server.connectionStatus,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${server.host}:${server.port} · ${server.sshUser}',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              if (metric != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                _MetricRow(metric: metric!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metric});
  final MetricLatest metric;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        _MetricCell(
            label: 'CPU', value: '${metric.cpuPct.toStringAsFixed(0)}%'),
        _MetricCell(label: '内存', value: '${metric.memPct.toStringAsFixed(0)}%'),
        _MetricCell(
            label: '磁盘', value: '${metric.diskPct.toStringAsFixed(0)}%'),
        _MetricCell(label: '负载', value: metric.load1.toStringAsFixed(2)),
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.text),
        ),
      ],
    );
  }
}
