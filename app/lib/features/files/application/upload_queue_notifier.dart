import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files_repository.dart';
import '../domain/files_error.dart';
import '../domain/remote_path.dart';
import '../domain/upload_task.dart';

/// 上传队列（全局、**非** autoDispose）。
///
/// 为什么必须活在 App 级容器里：上传是「按下开始之后可能切 Tab、锁屏、
/// 甚至离开服务器详情页」的长任务。如果用 autoDispose，最后一个监听者消失时
/// 状态机连同在飞的请求一起被销毁，用户看到的就是「一离开页面进度归零 / 直接失败」。
class UploadQueueNotifier extends StateNotifier<UploadQueueState> {
  UploadQueueNotifier(this._repo) : super(const UploadQueueState());

  final FilesRepository _repo;

  /// 4MiB 分片：太小则分片数暴涨（每片一次独立的 HTTP + SFTP 写入固定开销），
  /// 太大则单片超时/重试的代价过高。4MiB 是弱网下仍能单片完成、且固定开销被摊薄的值。
  static const int chunkSize = 4 * 1024 * 1024;

  /// 首传之后的重试间隔：1s / 3s / 8s（共 3 次重试，4 次尝试）。
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];

  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Map<String, int> _speeds = <String, int>{};
  final Map<String, DateTime> _ticks = <String, DateTime>{};

  /// 每个任务一个「代号」。任何会打断当前驱动循环的动作（暂停/继续/取消）
  /// 都换一个代号，旧循环里所有写状态的操作随即变成空操作。
  ///
  /// 这是整套代码里最容易被忽略的一处：暂停一个正在 fly 的分片时，那个分片的
  /// 响应还会回来（或者抛 cancel 异常），如果它仍能写状态，就会在用户点了「继续」
  /// 之后把任务重新标成「已暂停」，界面开始来回跳。
  final Map<String, int> _gen = <String, int>{};
  int _genSeq = 0;
  int _taskSeq = 0;

  UploadTask? task(String id) {
    for (final t in state.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 入队并立刻开始。返回非 null 表示被拒绝（文案直接展示给用户）。
  ///
  /// 同一 `(serverId, remotePath)` 只允许一个在飞任务：服务端写文件是
  /// 从 offset 开始覆盖写、没有文件锁，两个任务交错写同一个文件会得到
  /// 一个字节乱序的垃圾文件。所以这里**拒绝**重复入队，而不是排到后面等——
  /// 排队只会让用户以为「多传几遍更保险」。
  String? enqueue({
    required int serverId,
    required String remotePath,
    required String localPath,
    required int totalBytes,
  }) {
    final busy = state.tasks.any((t) =>
        t.serverId == serverId &&
        t.remotePath == remotePath &&
        !t.status.isTerminal);
    if (busy) {
      return '${baseNameOf(remotePath)} 已在上传队列中，先完成或取消它再重传';
    }
    if (totalBytes < 0) return '读不到本地文件大小，无法上传';

    final id = 'up${_taskSeq++}';
    final task = UploadTask(
      id: id,
      serverId: serverId,
      dirPath: parentOf(remotePath),
      remotePath: remotePath,
      localPath: localPath,
      name: baseNameOf(remotePath),
      totalBytes: totalBytes,
    );
    _emit(<UploadTask>[...state.tasks, task]);
    _start(id);
    return null;
  }

  /// 暂停单个任务：立刻掐掉在飞的分片，不等它自己超时。
  void pause(String id) {
    final t = task(id);
    if (t == null || t.status.isTerminal || t.status == UploadStatus.paused) {
      return;
    }
    _gen[id] = ++_genSeq; // 旧循环失效
    _tokens.remove(id)?.cancel('已暂停');
    _speeds.remove(id);
    _replace(
      t.copyWith(status: UploadStatus.paused, bytesPerSec: 0, message: '已暂停'),
    );
  }

  void pauseAll() {
    for (final t in state.tasks.toList(growable: false)) {
      pause(t.id);
    }
  }

  /// 继续：**先向服务端要当前文件大小**，从那里续写。
  ///
  /// 不能用本地记录的 sentBytes 当起点：上次请求可能已经把字节写进服务端，
  /// 只是响应在回来的路上丢了。用本地值续传会在文件中间留下一段空洞
  /// （SFTP 定位写不会自动补齐），文件看起来完整、内容却是坏的。
  Future<void> resume(String id) async {
    final t = task(id);
    if (t == null || t.status != UploadStatus.paused) return;

    _replace(t.copyWith(status: UploadStatus.queued, clearMessage: true, bytesPerSec: 0));
    var offset = 0;
    try {
      offset = await _repo.statSize(t.serverId, t.remotePath);
    } on Object {
      offset = 0; // 远端还没有这个文件（首片就失败了）：从头开始
    }
    final current = task(id);
    if (current == null || current.status != UploadStatus.queued) return;
    // 远端比本地还大：同名文件被别人写大了，续写只会叠加垃圾，只能从头覆盖。
    if (offset > current.totalBytes) offset = 0;
    _replace(current.copyWith(sentBytes: offset));
    _start(id);
  }

  Future<void> resumeAll() async {
    for (final t in state.tasks
        .where((t) => t.status == UploadStatus.paused)
        .toList(growable: false)) {
      await resume(t.id);
    }
  }

  /// 取消（并移除）任务。在飞的分片会被立即取消。
  void remove(String id) {
    _gen[id] = ++_genSeq;
    _tokens.remove(id)?.cancel('已取消上传');
    _speeds.remove(id);
    _emit(state.tasks.where((t) => t.id != id).toList(growable: false));
  }

  void clearDone() {
    _emit(state.tasks
        .where((t) => t.status != UploadStatus.done)
        .toList(growable: false));
  }

  void clearFailed() {
    _emit(state.tasks
        .where((t) => t.status != UploadStatus.failed)
        .toList(growable: false));
  }

  @override
  void dispose() {
    for (final token in _tokens.values) {
      if (!token.isCancelled) token.cancel('上传队列已释放');
    }
    _tokens.clear();
    super.dispose();
  }

  // ── 内部：状态写入 ────────────────────────────────────────────────

  void _emit(List<UploadTask> tasks) =>
      state = UploadQueueState(tasks: tasks, doneCount: state.doneCount);

  void _replace(UploadTask next, {bool bumpDone = false}) {
    final tasks = <UploadTask>[
      for (final t in state.tasks) t.id == next.id ? next : t,
    ];
    state = UploadQueueState(
      tasks: tasks,
      doneCount: state.doneCount + (bumpDone ? 1 : 0),
    );
  }

  /// 带代号校验的状态写入：代号不匹配说明这个循环已经被暂停/取消接管了。
  void _patch(
    String id,
    int gen, {
    UploadStatus? status,
    int? sentBytes,
    int? bytesPerSec,
    String? message,
    bool clearMessage = false,
  }) {
    if (_gen[id] != gen) return;
    final current = task(id);
    if (current == null) return;
    final next = current.copyWith(
      status: status,
      sentBytes: sentBytes,
      bytesPerSec: bytesPerSec,
      message: message,
      clearMessage: clearMessage,
    );
    _replace(
      next,
      bumpDone:
          current.status != UploadStatus.done && next.status == UploadStatus.done,
    );
  }

  // ── 内部：驱动 ────────────────────────────────────────────────────

  void _start(String id) {
    final gen = ++_genSeq;
    _gen[id] = gen;
    _ticks[id] = DateTime.now();
    unawaited(_drive(id, gen));
  }

  Future<void> _drive(String id, int gen) async {
    _patch(id, gen, status: UploadStatus.uploading, clearMessage: true);
    try {
      while (true) {
        final t = task(id);
        if (t == null || _gen[id] != gen) return;

        // 空文件：后端 offset=0 时会截断创建，必须显式发一次空分片，
        // 否则服务端上根本没有这个文件，最后一步 stat 校验会直接失败。
        if (t.totalBytes == 0) {
          final written = await _sendChunk(id, gen, t, Uint8List(0), 0);
          if (written == null) return;
          break;
        }

        if (t.sentBytes >= t.totalBytes) break;

        final offset = t.sentBytes;
        final length = math.min(chunkSize, t.totalBytes - offset);
        final bytes = await _readLocal(t.localPath, offset, length);
        if (bytes == null || bytes.length != length) {
          _patch(
            id,
            gen,
            status: UploadStatus.failed,
            message: '本地文件在上传过程中被改动或删除了，请重新上传',
          );
          return;
        }

        final written = await _sendChunk(id, gen, t, bytes, offset);
        if (written == null) return;

        final now = DateTime.now();
        final elapsed = now.difference(_ticks[id] ?? now).inMilliseconds;
        if (elapsed > 0) {
          final instant = (written * 1000 / elapsed).round();
          final prev = _speeds[id] ?? 0;
          _speeds[id] = prev == 0
              ? instant
              : (prev * 0.6 + instant * 0.4).round(); // 平滑，避免数字乱跳
        }
        _ticks[id] = now;
        _patch(
          id,
          gen,
          sentBytes: offset + written,
          bytesPerSec: _speeds[id] ?? 0,
        );
      }

      // 唯一成功判据：服务端文件大小 == 本地大小。
      // 上传接口返回 200 只说明「请求被处理了」，服务端写一半也是 200。
      _patch(id, gen, status: UploadStatus.verifying);
      final beforeVerify = task(id);
      if (beforeVerify == null || _gen[id] != gen) return;
      final int remote;
      try {
        remote = await _repo.statSize(
          beforeVerify.serverId,
          beforeVerify.remotePath,
        );
      } on Object catch (e) {
        _patch(
          id,
          gen,
          status: UploadStatus.failed,
          message: '无法校验写入结果：${describeFilesError(e, path: beforeVerify.remotePath)}',
        );
        return;
      }
      if (_gen[id] != gen) return;
      final finished = task(id);
      if (finished == null) return;
      if (remote == finished.totalBytes) {
        _patch(
          id,
          gen,
          status: UploadStatus.done,
          sentBytes: finished.totalBytes,
          bytesPerSec: 0,
          clearMessage: true,
        );
      } else {
        _patch(
          id,
          gen,
          status: UploadStatus.failed,
          message: '服务端大小不符：本地 ${finished.totalBytes} 字节，'
              '服务端 $remote 字节。可能磁盘已满或写入被截断，请检查服务器磁盘空间后重传。',
        );
      }
    } finally {
      // 只清掉本代自己的 token：任务被暂停后立刻继续时，新一代的驱动已经
      // 建了新的 token，这里若无条件 remove 会把它的取消能力一起抹掉。
      if (_gen[id] == gen) _tokens.remove(id);
    }
  }

  /// 发一片（含 1s/3s/8s 三次重试）。
  ///
  /// 返回服务端确认写入的字节数；返回 null 表示**本循环不该继续**：
  /// 已被暂停 / 取消 / 已置为暂停态（重试用尽）。
  Future<int?> _sendChunk(
    String id,
    int gen,
    UploadTask t,
    Uint8List bytes,
    int offset,
  ) async {
    Object? last;
    for (var attempt = 0; attempt <= _backoff.length; attempt++) {
      if (_gen[id] != gen) return null;
      final token = CancelToken();
      _tokens[id] = token;
      try {
        final written = await _repo.uploadChunk(
          t.serverId,
          t.remotePath,
          offset: offset,
          bytes: bytes,
          cancelToken: token,
        );
        if (_gen[id] != gen) return null;
        if (bytes.isNotEmpty && written <= 0) {
          _patch(
            id,
            gen,
            status: UploadStatus.paused,
            message: '服务端没有确认写入（written=0），可以继续重试',
          );
          return null;
        }
        return written;
      } on Object catch (e) {
        // 暂停/取消/移除导致的取消不算失败：不要计入重试次数。
        if (_gen[id] != gen) return null;
        if (e is DioException && e.type == DioExceptionType.cancel) return null;
        last = e;
        if (attempt < _backoff.length) {
          await Future<void>.delayed(_backoff[attempt]);
          if (_gen[id] != gen) return null;
        }
      } finally {
        if (identical(_tokens[id], token)) _tokens.remove(id);
      }
    }
    // 重试用尽 → 「已暂停」而不是「失败」：换个网络/等服务器缓过来还能接着传。
    final reason = last == null
        ? '上传中断'
        : describeFilesError(last, path: t.remotePath);
    _patch(
      id,
      gen,
      status: UploadStatus.paused,
      message: '$reason（已自动重试 ${_backoff.length} 次）',
    );
    return null;
  }

  /// 读本地分片。返回 null = 文件已不可读。
  Future<Uint8List?> _readLocal(String path, int offset, int length) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      await raf.setPosition(offset);
      return await raf.read(length);
    } on Object {
      return null;
    } finally {
      await raf?.close();
    }
  }
}

/// 全局上传队列。
///
/// 刻意用 `StateNotifierProvider`（非 autoDispose）：见 [UploadQueueNotifier] 类注释。
final uploadQueueProvider =
    StateNotifierProvider<UploadQueueNotifier, UploadQueueState>(
  (ref) => UploadQueueNotifier(ref.watch(filesRepositoryProvider)),
);
