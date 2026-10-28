import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../application/alerts_notifier.dart';
import '../domain/alert_event.dart';

/// 通知详情（M9.3 步4）：展示单条告警；进入即标记已读（B7）。
class AlertDetailPage extends ConsumerStatefulWidget {
  const AlertDetailPage({super.key, required this.alertId});
  final String alertId;

  @override
  ConsumerState<AlertDetailPage> createState() => _AlertDetailPageState();
}

class _AlertDetailPageState extends ConsumerState<AlertDetailPage> {
  @override
  void initState() {
    super.initState();
    final id = int.tryParse(widget.alertId);
    if (id != null) {
      // 进入详情即视为已读（乐观更新 + 后端同步）。
      Future.microtask(() => ref.read(alertsProvider.notifier).markRead(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(alertsProvider).value ?? const <AlertEvent>[];
    final id = int.tryParse(widget.alertId);
    AlertEvent? alert;
    for (final a in list) {
      if (a.id == id) {
        alert = a;
        break;
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('通知详情')),
      body: alert == null
          ? const Center(child: Text('通知不存在或已过期'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  alert.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '级别：${alert.severity}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                Text(
                  '时间：${alert.createdAt.toLocal()}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                const Divider(height: 24),
                Text(alert.message),
              ],
            ),
    );
  }
}
