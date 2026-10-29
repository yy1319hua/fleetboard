import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../application/overview_notifier.dart';
import '../domain/bootstrap.dart';
import 'server_card.dart';

/// 总览页（Tab 1，M9.2 落地）。
///
/// 消费 GET /api/bootstrap：服务器卡片列表（名/状态/指标摘要）+ 顶部未读告警数 + 版本。
/// 下拉刷新重拉；前台轮询（OverviewNotifier 30s + onResumed）更新未读告警（满足 B2）。
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authNotifierProvider);
    final bootstrap = ref.watch(overviewProvider);

    // 冷启动恢复中：全屏深色底品牌化 splash（与启动窗口背景同色），
    // 无 AppBar 突现、无灰白闪屏，会话恢复完再进正常页面。
    if (!auth.initialized) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Fleetboard',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: AppColors.text,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('总览'),
        actions: <Widget>[
          if (bootstrap.value != null)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: Center(
                child: Text(
                  '未读 ${bootstrap.value!.unreadAlerts}',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.accent),
                ),
              ),
            ),
        ],
      ),
      body: bootstrap.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(message: e.toString()),
        data: (data) => _OverviewContent(data: data),
      ),
    );
  }
}

class _OverviewContent extends ConsumerWidget {
  const _OverviewContent({required this.data});
  final BootstrapResponse data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () => ref.read(overviewProvider.notifier).refresh(),
      child: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Text(
                '版本 ${data.version} · schema ${data.schema}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.muted),
              ),
            ),
          ),
          if (data.servers.isEmpty)
            const SliverFillRemaining(
              child: Center(child: Text('暂无被管服务器')),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final server = data.servers[index];
                  final metric = data.metrics[server.id.toString()];
                  return ServerCard(server: server, metric: metric);
                },
                childCount: data.servers.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '加载失败：$message',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: () => ref.read(overviewProvider.notifier).load(),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
