import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/providers.dart';
import '../domain/metric_series.dart';

/// 历史指标仓储。
///
/// 契约：`GET /api/servers/:id/metrics?range=24h|7d`，data 为
/// `{range, step_sec, count, points}`。range 只接受这两个值（后端会 400），
/// 所以 UI 不要提供「自定义时间窗」——后端没有这个能力，做了就是假功能。
class MetricsRepository {
  MetricsRepository(this._dio);

  final Dio _dio;

  Future<MetricSeries> fetch(int serverId, String range) async {
    final resp = await _dio.get<dynamic>(
      '/api/servers/$serverId/metrics',
      queryParameters: <String, dynamic>{'range': range},
    );
    final raw = resp.data;
    if (raw is! Map<String, dynamic>) {
      throw const ApiException(message: '响应格式异常');
    }
    final code = raw['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException(code: code, message: raw['msg'] as String? ?? '获取指标失败');
    }
    final data = raw['data'];
    if (data is! Map<String, dynamic>) {
      return MetricSeries(range: range, stepSec: 0, points: const []);
    }
    final points = <MetricPoint>[];
    final list = data['points'];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          points.add(MetricPoint.fromJson(item));
        }
      }
    }
    return MetricSeries(
      range: (data['range'] as String?) ?? range,
      stepSec: (data['step_sec'] as num?)?.toInt() ?? 0,
      points: points,
    );
  }
}

final metricsRepositoryProvider = Provider<MetricsRepository>(
  (ref) => MetricsRepository(ref.watch(jsonDioProvider)),
);
