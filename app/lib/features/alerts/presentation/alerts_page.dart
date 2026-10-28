import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_dot.dart';
import '../application/alerts_notifier.dart';
import '../domain/alert_event.dart';

/// 告警级别 -> 语义色。
StatusKind _kindFromSeverity(String severity) => switch (severity) {
      'critical' || 'high' => StatusKind.danger,
      'warning' || 'warn' || 'medium' => StatusKind.warn,
      'info' || 'low' => StatusKind.info,
      _ => StatusKind.idle,
    };

/// 通知中心（Tab 2，M9.3 步4）：列表 + 已读（B7 与 Web 同源）。
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(alertsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载失败：$e'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => ref.read(alertsProvider.notifier).load(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) return const Center(child: Text('暂无通知'));
          return RefreshIndicator(
            onRefresh: () => ref.read(alertsProvider.notifier).refresh(),
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final a = list[i];
                return ListTile(
                  leading: StatusDot(_kindFromSeverity(a.severity)),
                  title: Text(
                    a.title,
                    style: TextStyle(
                      fontWeight:
                          a.isRead ? FontWeight.normal : FontWeight.w600,
                      color: a.isRead ? AppColors.muted : AppColors.text,
                    ),
                  ),
                  subtitle: Text(
                    a.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: a.isRead
                      ? null
                      : TextButton(
                          onPressed: () =>
                              ref.read(alertsProvider.notifier).markRead(a.id),
                          child: const Text('已读'),
                        ),
                  onTap: () {
                    ref.read(alertsProvider.notifier).markRead(a.id);
                    context.go('/alerts/${a.id}');
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}
