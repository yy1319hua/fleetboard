import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/providers.dart';
import '../domain/container.dart';

/// 容器仓储：GET /api/servers/:id/containers。
///
/// 该端点 data 为数组（非对象），[unwrap] 仅处理对象型 data，故此处手动解析信封。
class ContainersRepository {
  ContainersRepository(this._dio);

  final Dio _dio;

  Future<List<Container>> list(int serverId) async {
    final resp = await _dio.get<dynamic>('/api/servers/$serverId/containers');
    final raw = resp.data as Map<String, dynamic>;
    final code = raw['code'] as int? ?? 0;
    if (code != 0) {
      throw ApiException(
        code: code,
        message: raw['msg'] as String? ?? '获取容器列表失败',
      );
    }
    final data = raw['data'];
    if (data is! List) return const [];
    return data
        .map((e) => Container.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final containersRepositoryProvider = Provider<ContainersRepository>(
  (ref) => ContainersRepository(ref.watch(dioProvider)),
);
