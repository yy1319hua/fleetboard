import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/job.dart';

/// 任务仓储：包更新（SSE）、job 快照（续接）、取消。
class JobsRepository {
  JobsRepository(this._dio);

  final Dio _dio;

  /// 读取 job 快照（断连续接 / 回前台续接）。
  Future<Job> getJob(String jobId) async {
    final resp = await _dio.get<dynamic>('/api/jobs/$jobId');
    return unwrap<Job>(resp.data, Job.fromJson);
  }

  /// 取消 job（DELETE /api/jobs/:id）。
  Future<Job> cancelJob(String jobId) async {
    final resp = await _dio.delete<dynamic>('/api/jobs/$jobId');
    return unwrap<Job>(resp.data, Job.fromJson);
  }

  /// 触发包更新：POST 返回 202 + SSE 流，逐帧 yield。
  /// opId 传入 X-Client-Op-Id 做幂等防重复（B6）。
  Stream<SseEvent> startPackageUpdate(int serverId, {String? opId}) async* {
    final resp = await _dio.post<ResponseBody>(
      '/api/servers/$serverId/packages/update',
      options: Options(
        responseType: ResponseType.stream,
        headers: <String, dynamic>{
          'Accept': 'text/event-stream',
          if (opId != null) 'X-Client-Op-Id': opId,
        },
        validateStatus: (s) => s != null && s >= 200 && s < 500,
      ),
    );
    final body = resp.data;
    if (body == null) return;

    final buffer = StringBuffer();
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.startsWith('data:')) {
        buffer.write(line.substring(5).trimLeft());
      } else if (line.isEmpty && buffer.isNotEmpty) {
        // 空行 = 一帧结束
        final raw = buffer.toString();
        buffer.clear();
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            yield SseEvent.fromJson(decoded);
          }
        } on Object {
          // 忽略无法解析的帧（保持流不中断）
        }
      }
    }
  }
}

final jobsRepositoryProvider = Provider<JobsRepository>(
  (ref) => JobsRepository(ref.watch(dioProvider)),
);
