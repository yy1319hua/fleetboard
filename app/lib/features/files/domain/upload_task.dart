import 'file_sizes.dart';

/// 上传任务状态。
///
/// [paused] 与 [failed] 必须分开：
///  - paused = 网络断了/服务端 5xx，**再试可能成功**，所以给「继续」；
///  - failed = 已经确定失败（本地文件被删、服务端大小对不上），继续也没用，只能移除或重传。
/// 合成一个状态的话，UI 只能给出「重试」按钮，而磁盘满导致的失败重试一万次也不会成功。
enum UploadStatus { queued, uploading, paused, verifying, done, failed }

extension UploadStatusLabel on UploadStatus {
  String get label => switch (this) {
        UploadStatus.queued => '等待上传',
        UploadStatus.uploading => '上传中',
        UploadStatus.paused => '已暂停',
        UploadStatus.verifying => '校验中',
        UploadStatus.done => '已完成',
        UploadStatus.failed => '失败',
      };

  bool get isTerminal => this == UploadStatus.done || this == UploadStatus.failed;
  bool get isRunning =>
      this == UploadStatus.uploading ||
      this == UploadStatus.verifying ||
      this == UploadStatus.queued;
}

/// 一个上传任务（不可变快照，队列每次变更产生新实例）。
class UploadTask {
  const UploadTask({
    required this.id,
    required this.serverId,
    required this.dirPath,
    required this.remotePath,
    required this.localPath,
    required this.name,
    required this.totalBytes,
    this.sentBytes = 0,
    this.status = UploadStatus.queued,
    this.message,
    this.bytesPerSec = 0,
  });

  final String id;
  final int serverId;

  /// 目标目录：上传结束后要刷新的正是这个目录。
  final String dirPath;
  final String remotePath;
  final String localPath;
  final String name;
  final int totalBytes;

  /// **服务端已确认写入**的字节数（取响应里的 written 累加），
  /// 不是「已提交给 socket 的字节数」——后者在网络拥塞时虚高，
  /// 断线后会看到进度条倒退。
  final int sentBytes;

  final UploadStatus status;

  /// 暂停/失败原因（中文，直接展示）。
  final String? message;

  /// 平滑后的瞬时速率（字节/秒），仅上传中有效。
  final int bytesPerSec;

  double get progress {
    if (totalBytes <= 0) {
      return status == UploadStatus.done ? 1 : 0;
    }
    return (sentBytes / totalBytes).clamp(0.0, 1.0);
  }

  String get sizeLabel => '${formatBytes(sentBytes)} / ${formatBytes(totalBytes)}';

  UploadTask copyWith({
    int? sentBytes,
    UploadStatus? status,
    int? bytesPerSec,
    String? message,
    bool clearMessage = false,
  }) {
    return UploadTask(
      id: id,
      serverId: serverId,
      dirPath: dirPath,
      remotePath: remotePath,
      localPath: localPath,
      name: name,
      totalBytes: totalBytes,
      sentBytes: sentBytes ?? this.sentBytes,
      status: status ?? this.status,
      message: clearMessage ? null : (message ?? this.message),
      bytesPerSec: bytesPerSec ?? this.bytesPerSec,
    );
  }
}

/// 队列状态。
class UploadQueueState {
  const UploadQueueState({this.tasks = const <UploadTask>[], this.doneCount = 0});

  final List<UploadTask> tasks;

  /// 单调递增的完成计数。
  ///
  /// 目录页靠它判断「我这次重建之后，队列是否又完成过任务」——用一个计数器
  /// 而不是监听单个任务，是因为用户可能已经离开过这个页面（Widget 重建），
  /// 那条「某某任务完成」的事件早就没人接了。
  final int doneCount;

  List<UploadTask> forServer(int serverId) => tasks
      .where((t) => t.serverId == serverId)
      .toList(growable: false);

  int get activeCount => tasks.where((t) => !t.status.isTerminal).length;

  bool get hasActive => activeCount > 0;
}
