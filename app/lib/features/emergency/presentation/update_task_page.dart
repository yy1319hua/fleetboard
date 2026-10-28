import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 包更新任务页（全屏占位空壳，M9.1 仅路由占位）。
///
/// M9.4 落地：发起 apt 升级 -> 202 + jobId；全屏页计时/行数/末行/取消；
/// 切走取消 SSE 保 jobId，回前台 GET /api/jobs/:id 续接（B4）。
class UpdateTaskPage extends ConsumerWidget {
  const UpdateTaskPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('包更新')),
      body: const Center(child: Text('包更新占位 · M9.4')),
    );
  }
}
