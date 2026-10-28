import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../application/package_update_controller.dart';
import '../domain/job.dart';

/// 包更新任务页（M9.4）：发起 apt 升级 → 202+jobId；进度/计时/取消；
/// 断连/回前台用 jobId 续接（B4）；取消走 DELETE（B6）。
class UpdateTaskPage extends ConsumerStatefulWidget {
  const UpdateTaskPage({super.key, required this.serverId});
  final String serverId;

  @override
  ConsumerState<UpdateTaskPage> createState() => _UpdateTaskPageState();
}

class _UpdateTaskPageState extends ConsumerState<UpdateTaskPage> {
  final ScrollController _scroll = ScrollController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 回前台/进入即尝试续接未完成任务（B4）。
    Future.microtask(
      () => ref.read(packageUpdateControllerProvider.notifier).resumeIfActive(),
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {}); // 刷新计时
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int? get _sid => int.tryParse(widget.serverId);

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(packageUpdateControllerProvider);
    if (state is UpdateRunning) _scrollToEnd();

    return Scaffold(
      appBar: AppBar(title: const Text('包更新')),
      body: Column(
        children: <Widget>[
          _header(context, state),
          const Divider(height: 1),
          Expanded(child: _lines(context, state)),
          _bottom(context, state),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, UpdateState state) {
    switch (state) {
      case UpdateIdle():
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            '将对服务器执行 apt-get update && upgrade -y。\n'
            '任务在服务端后台执行，切走/断网不中断，回来可续接。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        );
      case UpdateRunning(:final jobId, :final startedAt):
        final secs = DateTime.now().difference(startedAt).inSeconds;
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const LinearProgressIndicator(),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '运行中 · 已用时 ${_fmt(secs)}'
                '${jobId == null ? ' · 启动中…' : ' · 任务 ${_short(jobId)}'}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.muted),
              ),
            ],
          ),
        );
      case UpdateFinished(:final status, :final error):
        final (label, color) = switch (status) {
          JobStatus.done => ('更新完成', AppColors.ok),
          JobStatus.cancelled => ('已取消', AppColors.muted),
          JobStatus.failed => ('更新失败', AppColors.danger),
          _ => ('已结束', AppColors.info),
        };
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline, color: color, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  error == null ? label : '$label · $error',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: color),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _lines(BuildContext context, UpdateState state) {
    final lines = switch (state) {
      UpdateRunning(:final lines) => lines,
      UpdateFinished(:final lines) => lines,
      _ => const <String>[],
    };
    if (lines.isEmpty) {
      return Center(
        child: Text(
          state is UpdateRunning ? '等待输出…' : '暂无输出',
          style: const TextStyle(color: AppColors.muted),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      itemCount: lines.length,
      itemBuilder: (context, i) => Text(
        lines[i],
        style: const TextStyle(
          fontFamily: AppFonts.mono,
          fontSize: 12,
          height: 1.4,
          color: AppColors.text,
        ),
      ),
    );
  }

  Widget _bottom(BuildContext context, UpdateState state) {
    final nav = Navigator.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: switch (state) {
          UpdateIdle() => SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sid == null ? null : _start,
                child: const Text('开始更新'),
              ),
            ),
          UpdateRunning() => SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () =>
                    ref.read(packageUpdateControllerProvider.notifier).cancel(),
                child: const Text('取消任务'),
              ),
            ),
          UpdateFinished() => Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => nav.pop(),
                    child: const Text('返回'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: _sid == null
                        ? null
                        : () {
                            ref
                                .read(packageUpdateControllerProvider.notifier)
                                .reset();
                            _start();
                          },
                    child: const Text('重新更新'),
                  ),
                ),
              ],
            ),
        },
      ),
    );
  }

  void _start() {
    final sid = _sid;
    if (sid == null) return;
    ref.read(packageUpdateControllerProvider.notifier).start(sid);
  }

  String _fmt(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);
}
