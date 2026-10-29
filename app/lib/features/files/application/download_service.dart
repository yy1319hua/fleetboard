import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../data/files_repository.dart';
import '../domain/remote_path.dart';

/// 超过这个大小改走流式落盘。
///
/// 64MiB 是「Android 上还能安全整块读进内存」与「再大就必 OOM」的分界：
/// 一个 64MiB 的 `Uint8List` 在压缩后的堆里通常要占 64~128MB，
/// 而多数中低端机的 per-app 堆上限就是 256MB，再大就是随机闪退。
const int streamDownloadThreshold = 64 * 1024 * 1024;

/// 一次下载的落地结果。
class DownloadedFile {
  const DownloadedFile({
    required this.file,
    required this.size,
    this.bytes,
  });

  final File file;
  final int size;

  /// ≤ [streamDownloadThreshold] 时保留原始字节，供「另存到…」直接交给系统 SAF，
  /// 不必把临时文件再读一遍；大文件走流式落盘，这里为 null（内存里没有它）。
  final Uint8List? bytes;

  String get name => file.path.split('/').last;
}

/// 下载落盘服务（临时目录 + 唯一命名）。
///
/// 为什么必须落在临时目录而不是「下载」目录：Android 10+ 的共享存储需要 SAF
/// 或 MediaStore，App 不能直接往用户可见目录写。所以流程是
/// 「下载到 App 私有临时目录 → 用户选打开/分享/另存到」，另存那一步才走 SAF。
class DownloadService {
  DownloadService(this._repo);

  final FilesRepository _repo;

  /// [totalBytes] 来自目录列表里的条目大小，用来决定走哪条路径（内存/流式）。
  Future<DownloadedFile> run(
    int serverId,
    String remotePath, {
    required String name,
    required int totalBytes,
    CancelToken? cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = await _destinationDir();
    final dest = await _uniqueFile(dir, safeFileName(name));

    if (totalBytes > streamDownloadThreshold) {
      final written = await _repo.downloadToFile(
        serverId,
        remotePath,
        destPath: dest.path,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      return DownloadedFile(file: dest, size: written);
    }

    final bytes = await _repo.download(
      serverId,
      remotePath,
      cancelToken: cancelToken,
      onProgress: (received, total) =>
          onProgress?.call(received, total > 0 ? total : totalBytes),
    );
    await dest.writeAsBytes(bytes, flush: true);
    return DownloadedFile(
      file: dest,
      size: bytes.length,
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
  }

  Future<Directory> _destinationDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/fleetboard_download');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 同名冲突：`a.conf` → `a (1).conf`。
  ///
  /// 远端两个目录里可能有同名文件（比如每个 nginx 站点都叫 `default.conf`），
  /// 落到同一个临时目录时后一次会覆盖前一次，用户拿到的可能是上一次下载的内容。
  Future<File> _uniqueFile(Directory dir, String name) async {
    final taken = <String>{};
    await for (final entity in dir.list()) {
      final base = baseNameOf(entity.path);
      if (base.isNotEmpty) taken.add(base);
    }
    return File('${dir.path}/${freeName(name, taken)}');
  }

  /// 去掉会把路径解释成子目录或非法的字符。
  static String safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
    return cleaned;
  }
}
