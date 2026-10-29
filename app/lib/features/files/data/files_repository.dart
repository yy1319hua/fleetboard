import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/dio_client.dart';
import '../../../core/http/providers.dart';
import '../domain/file_entry.dart';

/// 文件管理仓储（浏览 / 重命名 / 复制 / 删除 / 文本读写 / 下载 / 上传）。
///
/// 全部走 `jsonDio` 的只有元数据类操作；下载与上传必须用 `streamDio`——
/// 大文件在 JSON 档的 20s 接收超时下会被中途掐断，报错还是「请求超时」。
class FilesRepository {
  FilesRepository(this._json, this._stream);

  final Dio _json;
  final Dio _stream;

  Future<FileListing> list(
    int serverId,
    String path, {
    String sort = 'name',
    String order = 'asc',
    int offset = 0,
    int limit = 200,
  }) async {
    final resp = await _json.get<dynamic>(
      '/api/servers/$serverId/files',
      queryParameters: <String, dynamic>{
        'path': path,
        'sort': sort,
        'order': order,
        'offset': offset,
        'limit': limit,
      },
    );
    final data = _data(resp.data, '读取目录失败');
    if (data is! Map<String, dynamic>) {
      return const FileListing(entries: [], total: 0, offset: 0, limit: 0);
    }
    final raw = data['entries'];
    final entries = <FileEntry>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) entries.add(FileEntry.fromJson(e));
      }
    }
    return FileListing(
      entries: entries,
      total: (data['total'] as num?)?.toInt() ?? entries.length,
      offset: (data['offset'] as num?)?.toInt() ?? 0,
      limit: (data['limit'] as num?)?.toInt() ?? limit,
    );
  }

  Future<void> rename(int serverId, String from, String to) async {
    final resp = await _json.post<dynamic>(
      '/api/servers/$serverId/files/rename',
      data: <String, dynamic>{'from': from, 'to': to},
    );
    _data(resp.data, '重命名失败');
  }

  Future<void> copy(int serverId, String from, String to) async {
    final resp = await _json.post<dynamic>(
      '/api/servers/$serverId/files/copy',
      data: <String, dynamic>{'from': from, 'to': to},
    );
    _data(resp.data, '复制失败');
  }

  Future<void> remove(int serverId, String path) async {
    final resp = await _json.delete<dynamic>(
      '/api/servers/$serverId/files',
      queryParameters: <String, dynamic>{'path': path},
    );
    _data(resp.data, '删除失败');
  }

  /// 读取文本内容（后端上限 1MiB，超限返回 400）。
  Future<String> readText(int serverId, String path) async =>
      (await readTextWithSize(serverId, path)).content;

  /// 读取文本内容 + 服务端字节数（在线编辑的冲突基线）。
  ///
  /// 需要把 size 一起带回来：编辑开始时的「文件有多大」是后来判断
  /// 「别人是否改过」的唯一依据，凭列表页的旧数据不可靠（列表可能已经放了几分钟）。
  Future<RemoteText> readTextWithSize(int serverId, String path) async {
    final resp = await _json.get<dynamic>(
      '/api/servers/$serverId/files/content',
      queryParameters: <String, dynamic>{'path': path},
    );
    final data = _data(resp.data, '读取文件失败');
    if (data is Map<String, dynamic>) {
      final content = (data['content'] as String?) ?? '';
      return RemoteText(
        content: content,
        size: (data['size'] as num?)?.toInt() ?? content.length,
      );
    }
    return const RemoteText(content: '', size: 0);
  }

  /// 原子写文本（后端：同目录临时文件 → 保留权限属主 → rename）。
  Future<void> writeText(int serverId, String path, String content) async {
    final resp = await _json.put<dynamic>(
      '/api/servers/$serverId/files/content',
      data: <String, dynamic>{'content': content},
      queryParameters: <String, dynamic>{'path': path},
    );
    _data(resp.data, '保存失败');
  }

  /// 取远端文件大小。**上传成功的唯一判据**（上传接口写一半也返回 200）。
  Future<int> statSize(int serverId, String path) async {
    final resp = await _json.get<dynamic>(
      '/api/servers/$serverId/files/stat',
      queryParameters: <String, dynamic>{'path': path},
    );
    final data = _data(resp.data, '读取文件信息失败');
    if (data is Map<String, dynamic>) {
      return (data['size'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// 下载文件（可带 Range 取分片），整块收进内存。
  ///
  /// 走 `streamDio`：JSON 档的 20s 接收超时会在几十 MB 的文件上误杀。
  /// 返回原始字节，落盘与「打开/分享」由 presentation 层决定
  /// （Android 上还要走 SAF，不能替用户选目录）。
  ///
  /// **只适合小文件**（本项目阈值 64MiB）。大文件走 [downloadToFile]：
  /// 一个 200MB 的文件读进 `List<int>` 在 Android 上会直接 OOM 被杀进程，
  /// 用户看到的是闪退而不是「下载失败」。
  ///
  /// [onProgress] 同时驱动进度条与 [StreamWatchdog]：没有字节增长证据时，
  /// 看门狗会在 90s 后取消请求——半开的 TCP 连接不会自己报错。
  Future<List<int>> download(
    int serverId,
    String path, {
    int? from,
    int? to,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final headers = <String, dynamic>{};
    if (from != null || to != null) {
      headers['Range'] = "bytes=${from ?? 0}-${to ?? ''}";
    }
    final token = cancelToken ?? CancelToken();
    final watchdog = StreamWatchdog(token);
    try {
      final resp = await _stream.get<List<int>>(
        '/api/servers/$serverId/files/download',
        queryParameters: <String, dynamic>{'path': path},
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          // Range 请求会拿到 206，非 Range 是 200；两者都算成功。
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
        cancelToken: token,
        onReceiveProgress: (received, total) {
          watchdog.touch();
          onProgress?.call(received, total);
        },
      );
      final data = resp.data;
      if (data == null) {
        throw const ApiException(message: '下载失败：响应为空');
      }
      return data;
    } finally {
      watchdog.dispose();
    }
  }

  /// 流式下载到本地文件（> 64MiB 走这条路径）。
  ///
  /// 为什么需要第二条路径：[download] 把整个响应收进内存，大文件必 OOM。
  /// 这里用 `ResponseType.stream` 边收边写盘，内存占用恒定在一个 socket 缓冲，
  /// 200MB 与 2GB 的表现一样。
  ///
  /// 返回写入的字节数。失败/取消时会删掉半截文件——否则用户「打开」时
  /// 拿到的是一个看起来正常、实际被截断的文件，比明确报错危险得多。
  Future<int> downloadToFile(
    int serverId,
    String path, {
    required String destPath,
    CancelToken? cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    final token = cancelToken ?? CancelToken();
    final watchdog = StreamWatchdog(token);
    RandomAccessFile? raf;
    var received = 0;
    try {
      final resp = await _stream.get<ResponseBody>(
        '/api/servers/$serverId/files/download',
        queryParameters: <String, dynamic>{'path': path},
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
        cancelToken: token,
      );
      final body = resp.data;
      if (body == null) {
        throw const ApiException(message: '下载失败：响应为空');
      }
      // 服务端没给 Content-Length 时 total 为 null（进度条转不确定态）。
      final lengthHeader = body.headers[Headers.contentLengthHeader];
      final total = (lengthHeader == null || lengthHeader.isEmpty)
          ? null
          : int.tryParse(lengthHeader.first);
      final file = File(destPath);
      await file.parent.create(recursive: true);
      raf = await file.open(mode: FileMode.writeOnly);
      await for (final chunk in body.stream) {
        await raf.writeFrom(chunk);
        received += chunk.length;
        watchdog.touch();
        onProgress?.call(received, total);
      }
      await raf.flush();
      return received;
    } on Object {
      _deleteQuietly(destPath);
      rethrow;
    } finally {
      watchdog.dispose();
      await raf?.close();
    }
  }

  /// 分片上传：body 为**裸字节**，offset 在 query（见后端 `uploadFileHandler`）。
  ///
  /// 两个容易踩错的地方：
  ///  1. body 必须是 `Uint8List`。dio 只对 Uint8List 走「二进制直通」，其它
  ///     `List<int>` 会进 JSON transformer，把字节编码成 "[12,34,...]" 文本字符串，
  ///     服务端写进去的就是这串字符——上传「成功」，文件内容全错。
  ///  2. 单片超时必须自己给足。4MiB 在 20KB/s 的弱网下要 200s 以上，
  ///     按 CRUD 档的 20s 设置会永远卡在同一位置失败，重试也没用。
  ///
  /// 返回服务端确认写入的字节数（响应里的 written），而不是假定等于 bytes.length：
  /// 后端 `io.Copy` 的返回值才是「真的落盘了多少」，这才是进度的唯一可信来源。
  Future<int> uploadChunk(
    int serverId,
    String path, {
    required int offset,
    required Uint8List bytes,
    CancelToken? cancelToken,
  }) async {
    final resp = await _stream.post<dynamic>(
      '/api/servers/$serverId/files/upload',
      queryParameters: <String, dynamic>{'path': path, 'offset': offset},
      data: bytes,
      options: Options(
        contentType: 'application/octet-stream',
        responseType: ResponseType.json,
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 2),
      ),
      cancelToken: cancelToken,
    );
    final data = _data(resp.data, '上传失败');
    if (data is Map<String, dynamic>) {
      return (data['written'] as num?)?.toInt() ?? bytes.length;
    }
    return bytes.length;
  }

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // 清理失败不应掩盖真正的传输错误。
    }
  }

  static dynamic _data(dynamic raw, String fallback) {
    if (raw is! Map<String, dynamic>) {
      throw ApiException(message: fallback);
    }
    final code = raw['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException(code: code, message: msgOf(raw, fallback));
    }
    return raw['data'];
  }

  static String msgOf(Map<String, dynamic> raw, String fallback) {
    final msg = raw['msg'] as String?;
    return (msg == null || msg.isEmpty) ? fallback : msg;
  }
}

final filesRepositoryProvider = Provider<FilesRepository>(
  (ref) => FilesRepository(
    ref.watch(jsonDioProvider),
    ref.watch(streamDioProvider),
  ),
);
