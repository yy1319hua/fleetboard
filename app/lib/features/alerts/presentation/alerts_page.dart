import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通知中心页（Tab 2，M9.1 占位空壳）。
///
/// M9.2/3 落地：通知列表 + 已读同步（B7）+ 未读角标；深链带 `?segment=&filter=` 直达。
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: const Center(child: Text('通知中心占位 · M9.2/M9.3')),
    );
  }
}
