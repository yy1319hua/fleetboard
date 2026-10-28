import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/jobs_repository.dart';
import '../domain/job.dart';

/// 包更新状态机。
sealed class UpdateState {
  const UpdateState();
}

class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

class UpdateRunning extends UpdateState {
  const UpdateRunning({
    required this.jobId,
    required this.lines,
    required this.startedAt,
  });
  final String? jobId;
  final List<String> lines;
  final DateTime startedAt;
}

class UpdateFinished extends UpdateState {
  const UpdateFinished({
    required this.status,
    required this.lines,
    this.error,
  });
  final JobStatus status;
  final List<String> lines;
  final String? error;
}

/// 包更新控制器：SSE 实时进度 + jobId 持久化 + 断连续接轮询（B4）+ 取消（B6）。
class PackageUpdateController extends StateNotifier<UpdateState> {
  PackageUpdateController(this._repo) : super(const UpdateIdle());

  final JobsRepository _repo;
  static const String _kJobId = 'active_package_job_id';

  StreamSubscription<SseEvent>? _sub;
  Timer? _poll;
  bool _disposed = false;

  /// 启动一次包更新（SSE 实时）；Running 时忽略（提交锁）。
  Future<void> start(int serverId) async {
    if (state is UpdateRunning) return;
    final opId = 'app-${DateTime.now().microsecondsSinceEpoch}';
    final startedAt = DateTime.now();
    final lines = <String>[];
    state = UpdateRunning(jobId: null, lines: lines, startedAt: startedAt);

    _sub = _repo.startPackageUpdate(serverId, opId: opId).listen(
      (event) async {
        if (_disposed) return;
        switch (event) {
          case SseStarted(:final jobId):
            if (jobId.isNotEmpty) {
              await _saveJobId(jobId);
              if (_disposed) return;
              final cur = state;
              state = UpdateRunning(
                jobId: jobId,
                lines: cur is UpdateRunning ? cur.lines : lines,
                startedAt: startedAt,
              );
            }
          case SseLine(:final line):
            lines.add(line);
            final cur = state;
            state = UpdateRunning(
              jobId: cur is UpdateRunning ? cur.jobId : null,
              lines: List<String>.of(lines),
              startedAt: startedAt,
            );
          case SseDone(:final ok, :final canceled, :final error):
            await _clearJobId();
            if (_disposed) return;
            state = UpdateFinished(
              status: canceled
                  ? JobStatus.cancelled
                  : (ok ? JobStatus.done : JobStatus.failed),
              lines: List<String>.of(lines),
              error: error,
            );
          case SseUnknown():
            break;
        }
      },
      onError: (Object _) => _resumeByPolling(lines, startedAt),
      onDone: () {
        // 流结束但仍在 Running（未收到 done 帧）→ 断连，续接
        if (state is UpdateRunning) _resumeByPolling(lines, startedAt);
      },
      cancelOnError: true,
    );
  }

  /// SSE 断开且未收 done：用 jobId 轮询 GET 续接（B4）。
  void _resumeByPolling(List<String> lines, DateTime startedAt) {
    if (_disposed) return;
    final cur = state;
    final jobId = cur is UpdateRunning ? cur.jobId : null;
    if (jobId == null || jobId.isEmpty) {
      state = UpdateFinished(
        status: JobStatus.failed,
        lines: List<String>.of(lines),
        error: '连接中断，无法续接（未拿到任务号）',
      );
      return;
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (t) async {
      try {
        final job = await _repo.getJob(jobId);
        final st = JobStatus.fromWire(job.status);
        if (_disposed) return;
        if (st.isTerminal) {
          t.cancel();
          await _clearJobId();
          if (_disposed) return;
          state = UpdateFinished(
            status: st,
            lines: List<String>.of(job.lines),
            error: job.error,
          );
        } else {
          state = UpdateRunning(
            jobId: jobId,
            lines: List<String>.of(job.lines),
            startedAt: startedAt,
          );
        }
      } on Object {
        // 网络抖动：下次 tick 重试
      }
    });
  }

  /// 回前台 / 页面进入：若有未完成任务，用持久化 jobId 续接（B4）。
  Future<void> resumeIfActive() async {
    if (state is UpdateRunning) return;
    final sp = await SharedPreferences.getInstance();
    final jobId = sp.getString(_kJobId);
    if (jobId == null || jobId.isEmpty) return;
    try {
      final job = await _repo.getJob(jobId);
      final st = JobStatus.fromWire(job.status);
      if (st.isTerminal) {
        await _clearJobId();
        if (_disposed) return;
        state = UpdateFinished(
          status: st,
          lines: List<String>.of(job.lines),
          error: job.error,
        );
      } else {
        final startedAt = DateTime.now();
        state = UpdateRunning(
          jobId: jobId,
          lines: List<String>.of(job.lines),
          startedAt: startedAt,
        );
        _resumeByPolling(job.lines, startedAt);
      }
    } on Object {
      // 任务可能已过期（24h TTL）→ 清 jobId
      await _clearJobId();
    }
  }

  /// 取消当前任务（DELETE /api/jobs/:id，B6 显式取消）。
  Future<void> cancel() async {
    final cur = state;
    final jobId = cur is UpdateRunning ? cur.jobId : null;
    if (jobId == null || jobId.isEmpty) return;
    try {
      await _repo.cancelJob(jobId);
      // 轮询/SSE 会把终态推上来；此处不强制改状态。
    } on Object {
      // 忽略：以后续快照为准
    }
  }

  /// 重置回 idle（重新发起）。
  void reset() {
    _sub?.cancel();
    _poll?.cancel();
    state = const UpdateIdle();
  }

  Future<void> _saveJobId(String id) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kJobId, id);
  }

  Future<void> _clearJobId() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kJobId);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _poll?.cancel();
    super.dispose();
  }
}

final packageUpdateControllerProvider =
    StateNotifierProvider.autoDispose<PackageUpdateController, UpdateState>(
  (ref) => PackageUpdateController(ref.watch(jobsRepositoryProvider)),
);
