import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/providers.dart';
import '../domain/server_facts.dart';

/// 主机静态配置仓储。
///
/// 契约：`GET /api/servers/:id/facts`，data 为 `model.ServerFacts`。
/// 404 表示后台还没采到（刚纳管 / 服务器离线），这里返回 null 由 UI 显示
/// 「等待采集」，不当作错误——否则概览页会整块进错误态，把「暂无数据」误报成故障。
class FactsRepository {
  FactsRepository(this._dio);

  final Dio _dio;

  Future<ServerFacts?> fetch(int serverId) async {
    try {
      final resp = await _dio.get<dynamic>('/api/servers/$serverId/facts');
      final raw = resp.data;
      if (raw is! Map<String, dynamic>) return null;
      final data = raw['data'];
      if (data is! Map<String, dynamic>) return null;
      return ServerFacts.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}

final factsRepositoryProvider = Provider<FactsRepository>(
  (ref) => FactsRepository(ref.watch(dioProvider)),
);

/// 单台服务器的配置。autoDispose：离开详情页即释放。
final serverFactsProvider =
    FutureProvider.autoDispose.family<ServerFacts?, int>((ref, serverId) async {
  return ref.watch(factsRepositoryProvider).fetch(serverId);
});
