import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/container.dart';
import '../domain/container_action.dart';

/// 容器仓储：列表与操作。
///
/// GET 列表的 data 为数组（非对象），[unwrap] 仅处理对象型 data，故列表手动解信封；
/// POST 操作的 data 为对象（container/action/output），走 [unwrap]。
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

  /// 对容器执行 start/stop/restart/rm。
  Future<ContainerActionResult> action(
    int serverId,
    String cid,
    ContainerActionType type,
  ) async {
    final resp = await _dio.post<dynamic>(
      '/api/servers/$serverId/containers/$cid/actions',
      data: <String, dynamic>{'action': type.wire},
    );
    return unwrap<ContainerActionResult>(
      resp.data,
      ContainerActionResult.fromJson,
    );
  }
}

final containersRepositoryProvider = Provider<ContainersRepository>(
  (ref) => ContainersRepository(ref.watch(dioProvider)),
);
