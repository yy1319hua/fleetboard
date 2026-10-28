import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通知详情页（二级占位空壳，M9.1 仅路由占位）。
///
/// M9.2/3 落地：去服务器深链 + 标记已读（Web 同步，B7）。
class AlertDetailPage extends ConsumerWidget {
  const AlertDetailPage({super.key, required this.alertId});
  final String alertId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知详情')),
      body: Center(child: Text('通知详情占位 · alertId=$alertId · M9.2/M9.3')),
    );
  }
}
