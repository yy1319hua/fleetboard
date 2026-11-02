import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/errors/api_exception.dart';
import 'package:app/core/http/envelope.dart';
import 'package:app/features/servers/data/servers_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 需求来源：M11.2 —— 纳管从「先建后测」翻转为「先测后存」。
///
/// 这里守着三条**会把错误固化进数据库**的约定：
/// ① 预检打的是 `/api/servers/probe`，不是创建接口（探不通不能留记录）；
/// ② 编辑场景要把 server_id 带上，后端才会用库里凭据补齐留空字段；
/// ③ 更新时凭据留空必须以空串提交，让后端按「不修改」处理，而不是把凭据清空。

/// 记录请求并按预设返回体应答的假适配器（不引入额外 mock 依赖）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final ResponseBody Function(RequestOptions options) _handler;
  RequestOptions? last;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    last = options;
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok([Map<String, dynamic>? data]) {
  return ResponseBody.fromString(
    jsonEncode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': data}),
    200,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

ResponseBody _fail(int status, String msg) {
  return ResponseBody.fromString(
    jsonEncode(<String, dynamic>{'code': status, 'msg': msg}),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    },
  );
}

Map<String, dynamic> _serverJson({int id = 1}) => <String, dynamic>{
      'id': id,
      'name': 'amd1',
      'host': '192.0.2.1',
      'port': 22,
      'ssh_user': 'root',
      'auth_method': 'key',
      'connection_status': 'unknown',
      'last_heartbeat': null,
      'tags': '',
      'created_at': '2026-11-03T00:00:00Z',
    };

ServersRepository _repo(_FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://panel.test',
      validateStatus: (_) => true,
      contentType: Headers.jsonContentType,
    ),
  );
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(EnvelopeInterceptor());
  return ServersRepository(dio);
}

void main() {
  group('probe', () {
    test('打预检端点而不是创建接口', () async {
      final adapter = _FakeAdapter(
        (_) => _ok(<String, dynamic>{'ok': true, 'elapsed_ms': 12}),
      );
      final ms = await _repo(adapter).probe(
        host: '192.0.2.1',
        port: 22,
        sshUser: 'root',
        authMethod: 'key',
        privateKey: 'KEY',
      );

      expect(ms, 12);
      expect(adapter.last?.method, 'POST');
      expect(
        adapter.last?.path,
        '/api/servers/probe',
        reason: '预检必须走不落库的端点，否则连不上也会留下记录',
      );
      expect(
        adapter.last?.data,
        containsPair('private_key', 'KEY'),
      );
    });

    test('编辑场景带上 server_id，供后端补齐留空凭据', () async {
      final adapter = _FakeAdapter(
        (_) => _ok(<String, dynamic>{'ok': true, 'elapsed_ms': 3}),
      );
      await _repo(adapter).probe(
        host: '192.0.2.1',
        port: 2222,
        sshUser: 'ai',
        authMethod: 'key',
        serverId: 7,
      );

      expect(adapter.last?.data, containsPair('server_id', 7));
      expect(
        adapter.last?.data,
        containsPair('private_key', ''),
        reason: '留空即空串，后端据此判定「沿用原凭据」',
      );
    });

    test('失败时把后端原因透传出去，便于原地显示', () async {
      final adapter = _FakeAdapter(
        (_) => _fail(502, '连接失败: dial tcp 192.0.2.1:22: i/o timeout'),
      );

      await expectLater(
        _repo(adapter).probe(
          host: '192.0.2.1',
          port: 22,
          sshUser: 'root',
          authMethod: 'key',
          privateKey: 'KEY',
        ),
        throwsA(
          isA<DioException>().having(
            (DioException e) => e.error,
            'error',
            isA<ApiException>().having(
              (ApiException a) => a.message,
              'message',
              contains('连接失败'),
            ),
          ),
        ),
      );
    });
  });

  group('update', () {
    test('走 PUT /api/servers/{id}', () async {
      final adapter = _FakeAdapter((_) => _ok(_serverJson(id: 7)));
      final updated = await _repo(adapter).update(
        7,
        name: 'renamed',
        host: '192.0.2.9',
        port: 2202,
        sshUser: 'ai',
        authMethod: 'key',
        tags: '生产',
      );

      expect(updated.id, 7);
      expect(adapter.last?.method, 'PUT');
      expect(adapter.last?.path, '/api/servers/7');
      expect(
        adapter.last?.data,
        allOf(
          containsPair('name', 'renamed'),
          containsPair('port', 2202),
          containsPair('private_key', ''),
          containsPair('password', ''),
          containsPair('key_pass', ''),
        ),
        reason: '凭据留空要显式传空串，后端才按「不修改」处理',
      );
    });
  });

  group('create', () {
    test('仍然走 POST /api/servers，不会被误改成预检', () async {
      final adapter = _FakeAdapter((_) => _ok(_serverJson()));
      await _repo(adapter).create(
        name: 'amd1',
        host: '192.0.2.1',
        port: 22,
        sshUser: 'root',
        authMethod: 'key',
        privateKey: 'KEY',
      );

      expect(adapter.last?.method, 'POST');
      expect(adapter.last?.path, '/api/servers');
    });
  });
}
