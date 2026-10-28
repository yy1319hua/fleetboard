import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 总览页（Tab 1，M9.1 占位空壳）。
///
/// M9.2 落地：启动拉 /api/bootstrap，消费 Settings；弱网渲染 SnapshotStore 快照 + OfflineBanner。
class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('总览')),
      body: const Center(child: Text('总览占位 · M9.2')),
    );
  }
}
