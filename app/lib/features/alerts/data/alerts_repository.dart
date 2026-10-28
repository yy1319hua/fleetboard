import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/providers.dart';
import '../domain/alert_event.dart';

/// 通知仓储：列表（可选仅未读）+ 标记已读。
class AlertsRepository {
  AlertsRepository(this._dio);

  final Dio _dio;

  Future<List<AlertEvent>> list({
    bool unreadOnly = false,
    int limit = 100,
  }) async {
    final resp = await _dio.get<dynamic>(
      '/api/alerts',
      queryParameters: <String, dynamic>{
        if (unreadOnly) 'unread': '1',
        'limit': '$limit',
      },
    );
    final raw = resp.data as Map<String, dynamic>;
    final code = raw['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException(
        code: code,
        message: raw['msg'] as String? ?? '获取通知失败',
      );
    }
    final data = raw['data'];
    if (data is! List) return const [];
    return data
        .map((e) => AlertEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 标记已读；信封 code!=0 时由 [EnvelopeInterceptor] 抛错。
  Future<void> markRead(int id) async {
    await _dio.post<dynamic>('/api/alerts/$id/read');
  }
}

final alertsRepositoryProvider = Provider<AlertsRepository>(
  (ref) => AlertsRepository(ref.watch(dioProvider)),
);
