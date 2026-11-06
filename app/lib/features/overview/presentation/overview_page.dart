import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/storage/bootstrap_cache.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/refresh_icon_button.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/application/auth_notifier.dart';
import '../application/overview_notifier.dart';
import '../domain/bootstrap.dart';
import 'server_card.dart';

/// 总览页（Tab 1，M9.2 落地）。
///
/// 消费 GET /api/bootstrap：服务器卡片列表（名/状态/指标摘要）+ 顶部未读告警数 + 版本。
/// 右上角刷新按钮重拉；前台轮询（OverviewNotifier 30s + onResumed）更新未读告警（满足 B2）。
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
                  fontSize: AppFontSizes.h1,
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
          // 原来这里是一段「未读 N」的纯文本：看着像入口，点下去没反应。
          // 通知 Tab 撤掉之后，它就是唯一入口，必须是能点、有角标、带无障碍标签的按钮。
          _AlertsBell(unread: bootstrap.value?.unreadAlerts ?? 0),
          RefreshIconButton(
            onRefresh: () => ref.read(overviewProvider.notifier).refresh(),
          ),
        ],
      ),
      body: bootstrap.when(
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                '正在连接面板…',
                style: TextStyle(
                    fontSize: AppFontSizes.bodySm, color: AppColors.muted),
              ),
            ],
          ),
        ),
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
    final cacheAt = ref.watch(overviewCacheAtProvider);
    return CustomScrollView(
      slivers: <Widget>[
        if (cacheAt != null)
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              color: AppColors.accentSoft,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.history, size: 14, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '显示缓存数据（${_hhmm(cacheAt)}）· 正在刷新…',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
          SliverToBoxAdapter(
            // 三档断点：<600 单列 / 600–1024 双栏 / ≥1024 三栏。
            // 用 Wrap + 固定宽度 SizedBox 而不是 SliverGrid(childAspectRatio)：
            // ServerCard 高度随「有没有指标」变化，固定宽高比会裁切内容。
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    AppBreakpoints.overviewColumns(constraints.maxWidth);
                final cardWidth = constraints.maxWidth / columns;
                return Wrap(
                  children: <Widget>[
                    for (final server in data.servers)
                      SizedBox(
                        width: cardWidth,
                        child: ServerCard(
                          server: server,
                          metric: data.metrics[server.id.toString()],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
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

/// `HH:mm` 两位补零，避免为一行时间引入 intl 依赖。
String _hhmm(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}


/// 告警入口：未读为 0 时是普通铃铛，有未读时染主色并挂角标。
///
/// 角标上限显示 99+：四位数会把图标挤变形，而「超过 99 条未读」这个量级
/// 本身已经说明问题，具体数字没有意义。
class _AlertsBell extends StatelessWidget {
  const _AlertsBell({required this.unread});

  final int unread;

  @override
  Widget build(BuildContext context) {
    final hot = unread > 0;
    final label = hot ? '告警通知，$unread 条未读' : '告警通知';
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: () => context.push('/alerts'),
        icon: Badge(
          isLabelVisible: hot,
          backgroundColor: AppColors.accent,
          textColor: AppColors.textInverse,
          label: Text(unread > 99 ? '99+' : '$unread'),
          child: Icon(
            hot ? Icons.notifications_active_outlined : Icons.notifications_none,
            color: hot ? AppColors.accent : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
