import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../../overview/domain/bootstrap.dart';

/// 服务器纳管仓储（M11）。
///
/// 契约要点：
/// - `POST /api/servers` 成功返 **201**，失败 400（name/host 为空或凭据非法）。
/// - `POST /api/servers/{id}/test` **要求服务器已存在**（后端先 parseID 再取记录），
///   所以「测试连接」不能作为创建前的预检；向导只能「先建后测」。
///   连接失败返 502 且服务端已把状态标为 offline —— 服务器仍然建好了。
/// - `DELETE /api/servers/{id}` 无返回体。
class ServersRepository {
  ServersRepository(this._dio);

  final Dio _dio;

  Future<List<Server>> list() async {
    final resp = await _dio.get<dynamic>('/api/servers');
    return unwrapList<Server>(resp.data, Server.fromJson);
  }

  Future<Server> create({
    required String name,
    required String host,
    required int port,
    required String sshUser,
    required String authMethod,
    String? password,
    String? privateKey,
    String? keyPass,
    String tags = '',
  }) async {
    final resp = await _dio.post<dynamic>(
      '/api/servers',
      data: <String, dynamic>{
        'name': name,
        'host': host,
        'port': port,
        'ssh_user': sshUser,
        'auth_method': authMethod,
        'password': password ?? '',
        'private_key': privateKey ?? '',
        'key_pass': keyPass ?? '',
        'tags': tags,
      },
    );
    return unwrap<Server>(resp.data, Server.fromJson);
  }

  Future<void> remove(int id) async {
    await _dio.delete<dynamic>('/api/servers/$id');
  }

  /// 测试连接。失败时抛 DioException（内层 ApiException 带后端「连接失败: ...」文案）。
  Future<String> test(int id) async {
    final resp = await _dio.post<dynamic>('/api/servers/$id/test');
    final data = unwrap<Map<String, dynamic>>(
      resp.data,
      (Map<String, dynamic> json) => json,
    );
    return (data['status'] as String?) ?? 'online';
  }
}

final serversRepositoryProvider = Provider<ServersRepository>(
  (ref) => ServersRepository(ref.watch(dioProvider)),
);
