import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/async_state_view.dart';
import '../application/upgrade_history_notifier.dart';
import '../domain/panel_upgrade.dart';

/// 面板升级历史：谁在什么时候把面板从哪一版换到了哪一版、成没成、花了多久。
///
/// 这是一条**低频但高价值**的记录：升级出问题时，用户第一句要问的就是
/// 「上次升的是哪一版、多久前、成功没有」，而不是翻服务器上的 journalctl。
class UpgradeHistoryPage extends ConsumerStatefulWidget {
  const UpgradeHistoryPage({super.key});

  @override
  ConsumerState<UpgradeHistoryPage> createState() => _UpgradeHistoryPageState();
}

class _UpgradeHistoryPageState extends ConsumerState<UpgradeHistoryPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(upgradeHistoryProvider.notifier).loadFirst(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = ref.watch(upgradeHistoryProvider);
    final notifier = ref.read(upgradeHistoryProvider.notifier);

    Widget body;
    if (history.loading && history.items.isEmpty) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(height: AppSpacing.md),
              Text('正在读取升级记录…'),
            ],
          ),
        ),
      );
    } else if (history.error != null && history.items.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined,
                  size: 36, color: AppColors.danger),
              const SizedBox(height: AppSpacing.md),
              Text(
                history.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.tonalIcon(
                onPressed: notifier.loadFirst,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    } else if (history.items.isEmpty) {
      // 空态必须说清「为什么空」和「怎么让它不空」，否则用户会以为是加载失败。
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.history, size: 36, color: theme.colorScheme.outline),
              const SizedBox(height: AppSpacing.md),
              Text(
                '还没有升级记录。第一次升级完成后会出现在这里',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextButton.icon(
                onPressed: notifier.loadFirst,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        itemCount: history.items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 0),
        itemBuilder: (context, index) {
          if (index == history.items.length) {
            return _Footer(
              state: history,
              onLoadMore: notifier.loadMore,
            );
          }
          return _RecordTile(record: history.items[index]);
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('升级历史'),
        actions: <Widget>[
          if (history.items.isNotEmpty)
            Text(
              '共 ${history.total} 条',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: notifier.loadFirst,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          // 有旧数据时刷新失败：保留列表，只在顶部提示，不清空已经看到的内容。
          if (history.error != null && history.items.isNotEmpty)
            InlineErrorBar(
              message: '${history.error!}（下面是上次读取的结果）',
              onRetry: notifier.loadFirst,
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});

  final UpgradeRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(record.status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${record.fromVersion.isEmpty ? '未知' : record.fromVersion}'
                  ' → '
                  '${record.toVersion.isEmpty ? '未知' : record.toVersion}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: AppFonts.mono,
                    color: AppColors.text,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withAlpha(28),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: color.withAlpha(120)),
                ),
                child: Text(
                  upgradeRecordStatusLabel(record.status),
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatUpgradeTime(record.startedAt)} 开始 · '
            '耗时 ${formatUpgradeDuration(record.durationMs)}',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
          if (record.errorCode.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '错误码 ${record.errorCode} · '
              '${describeUpgradeErrorCode(record.errorCode)}',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warn),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// 状态色：成功绿、失败红、回滚黄、进行中蓝、中断灰。
  Color _statusColor(String status) {
    return switch (status.trim()) {
      'done' => AppColors.ok,
      'failed' => AppColors.danger,
      'rolled_back' => AppColors.warn,
      'in_progress' => AppColors.info,
      _ => AppColors.idle,
    };
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.onLoadMore});

  final UpgradeHistoryState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (state.hasMore) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: OutlinedButton(
            onPressed: onLoadMore,
            child: Text('加载更多（已显示 ${state.items.length}/${state.total}）'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Center(
        child: Text(
          '已经到底了',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
      ),
    );
  }
}
