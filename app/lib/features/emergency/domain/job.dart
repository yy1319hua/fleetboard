import 'package:freezed_annotation/freezed_annotation.dart';

part 'job.freezed.dart';
part 'job.g.dart';

/// 任务状态（对齐后端 jobs.go JobStatus）。
enum JobStatus {
  pending,
  running,
  done,
  failed,
  cancelled;

  static JobStatus fromWire(String s) => switch (s) {
        'pending' => JobStatus.pending,
        'running' => JobStatus.running,
        'done' => JobStatus.done,
        'failed' => JobStatus.failed,
        'cancelled' => JobStatus.cancelled,
        _ => JobStatus.pending,
      };

  bool get isTerminal =>
      this == JobStatus.done ||
      this == JobStatus.failed ||
      this == JobStatus.cancelled;
}

/// 后台任务快照（对齐后端 Job.Snapshot）：GET /api/jobs/:id 与续接共用。
@freezed
class Job with _$Job {
  const factory Job({
    required String jobId,
    required String kind,
    required String status,
    required int serverId,
    required int uid,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(<String>[]) List<String> lines,
    String? error,
  }) = _Job;

  factory Job.fromJson(Map<String, dynamic> json) => _$JobFromJson(json);
}

/// 包更新 SSE 事件（packages/update 流）。
sealed class SseEvent {
  const SseEvent();

  static SseEvent fromJson(Map<String, dynamic> json) {
    final event = json['event'] as String?;
    return switch (event) {
      'started' => SseStarted(
          jobId: json['jobId'] as String? ?? '',
          message: json['message'] as String? ?? '',
        ),
      'line' => SseLine(json['line'] as String? ?? ''),
      'done' => SseDone(
          ok: json['ok'] as bool? ?? false,
          canceled: json['canceled'] as bool? ?? false,
          error: json['error'] as String?,
        ),
      _ => const SseUnknown(),
    };
  }
}

class SseStarted extends SseEvent {
  const SseStarted({required this.jobId, required this.message});
  final String jobId;
  final String message;
}

class SseLine extends SseEvent {
  const SseLine(this.line);
  final String line;
}

class SseDone extends SseEvent {
  const SseDone({required this.ok, this.canceled = false, this.error});
  final bool ok;
  final bool canceled;
  final String? error;
}

class SseUnknown extends SseEvent {
  const SseUnknown();
}
