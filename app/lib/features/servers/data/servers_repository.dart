import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../../overview/domain/bootstrap.dart';

/// 服务器纳管仓储（M11）。
///
/// 契约要点：
/// - `POST /api/servers/probe` **不落库**，只试连一次；成功返回耗时，失败 502。
///   纳管流程因此是「先测后存」：连不上就不产生任何记录。
/// - `POST /api/servers` 成功返 **201**，失败 400（name/host 为空或凭据非法）。
/// - `PUT /api/servers/{id}` 更新元信息与凭据；凭据三字段留空 = 保持原值。
///   成功后服务端关闭旧连接、状态置 unknown。
/// - `POST /api/servers/{id}/test` 用于已有记录的复测（列表页「测试连接」）。
/// - `DELETE /api/servers/{id}` 无返回体。
class ServersRepository {
  ServersRepository(this._dio);

  final Dio _dio;

  Future<List<Server>> list() async {
    final resp = await _dio.get<dynamic>('/api/servers');
    return unwrapList<Server>(resp.data, Server.fromJson);
  }

  /// 试连一次但**不落库**。
  ///
  /// [serverId] 非空表示编辑场景：后端会用库里已存的凭据补齐留空的字段，
  /// 所以只改端口时不必重新粘贴私钥。
  /// 失败抛 DioException（内层 ApiException 带「连接失败: ...」文案）。
  Future<int> probe({
    required String host,
    required int port,
    required String sshUser,
    required String authMethod,
    String? password,
    String? privateKey,
    String? keyPass,
    int? serverId,
  }) async {
    final resp = await _dio.post<dynamic>(
      '/api/servers/probe',
      data: <String, dynamic>{
        'host': host,
        'port': port,
        'ssh_user': sshUser,
        'auth_method': authMethod,
        'password': password ?? '',
        'private_key': privateKey ?? '',
        'key_pass': keyPass ?? '',
        if (serverId != null) 'server_id': serverId,
      },
    );
    final data = unwrap<Map<String, dynamic>>(
      resp.data,
      (Map<String, dynamic> json) => json,
    );
    return (data['elapsed_ms'] as num?)?.toInt() ?? 0;
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

  /// 更新服务器。凭据字段传 null = 不修改（后端按「留空」处理）。
  Future<Server> update(
    int id, {
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
    final resp = await _dio.put<dynamic>(
      '/api/servers/$id',
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
