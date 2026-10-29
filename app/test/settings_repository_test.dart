import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/errors/api_exception.dart';
import 'package:app/core/http/envelope.dart';
import 'package:app/features/settings/data/settings_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 需求来源：M11.1 —— 设置页从「只读」变成可写。
///
/// 这里测的不是网络，而是三条**会把用户数据搞坏**的约束：
/// ① 没改动就不发请求（空 map 打到后端等于无意义写）；
/// ② 只提交改动的 key（后端虽为 merge 语义，但全量回写会覆盖别处的并发修改）；
/// ③ 测试推送能用**未保存**的新 token（否则「先测后存」流程走不通）。

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

SettingsRepository _repo(_FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://panel.test',
      validateStatus: (_) => true,
      contentType: Headers.jsonContentType,
    ),
  );
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(EnvelopeInterceptor());
  return SettingsRepository(dio);
}

void main() {
  group('updateSettings', () {
    test('没有任何改动时不发请求', () async {
      final adapter = _FakeAdapter((_) => _ok());
      await _repo(adapter).updateSettings(<String, String>{});
      expect(adapter.calls, 0, reason: '空改动不应产生网络请求');
    });

    test('只把改动的 key 放进请求体', () async {
      final adapter = _FakeAdapter((_) => _ok());
      await _repo(adapter).updateSettings(<String, String>{
        'monitor.interval': '60',
      });

      expect(adapter.last?.method, 'PUT');
      expect(adapter.last?.path, '/api/settings');
      expect(
        adapter.last?.data,
        <String, String>{'monitor.interval': '60'},
        reason: '未改动的 key 不能一并回写，否则会覆盖别处的并发修改',
      );
    });
  });

  group('testChannel', () {
    test('传 token 时用未保存的值发送', () async {
      final adapter = _FakeAdapter((_) => _ok(<String, dynamic>{'sent': true}));
      await _repo(adapter).testChannel(token: '  abc123  ');

      expect(adapter.last?.path, '/api/settings/test-channel');
      expect(
        adapter.last?.data,
        <String, dynamic>{'token': 'abc123'},
        reason: '首尾空白必须去掉，否则 PushPlus 会判令牌无效',
      );
    });

    test('不传 token 时发空体，由服务端取已存值', () async {
      final adapter = _FakeAdapter((_) => _ok(<String, dynamic>{'sent': true}));
      await _repo(adapter).testChannel();
      expect(adapter.last?.data, <String, dynamic>{});
    });

    test('只有空白也算未传', () async {
      final adapter = _FakeAdapter((_) => _ok(<String, dynamic>{'sent': true}));
      await _repo(adapter).testChannel(token: '   ');
      expect(adapter.last?.data, <String, dynamic>{});
    });
  });

  group('changePassword', () {
    test('路径与字段名对齐后端契约', () async {
      final adapter = _FakeAdapter(
        (_) => _ok(<String, dynamic>{
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'expires_in': 900,
          'refresh_expires_at': 1900000000,
        }),
      );
      final token = await _repo(adapter)
          .changePassword(oldPassword: 'old-pass', newPassword: 'new-pass-123');

      expect(adapter.last?.path, '/api/auth/change-password');
      expect(adapter.last?.data, <String, dynamic>{
        'old_password': 'old-pass',
        'new_password': 'new-pass-123',
      });
      expect(token.accessToken, 'new-access');
      expect(token.refreshToken, 'new-refresh');
    });
  });

  group('describeApiError', () {
    test('优先展示服务端文案（DioException 内层信封）', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        error: const ApiException(code: 401, message: '旧密码错误'),
        type: DioExceptionType.badResponse,
      );
      expect(describeApiError(err), '旧密码错误');
    });

    test('连接失败给出可执行的网络提示', () {
      final err = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      expect(describeApiError(err), contains('无法连接服务器'));
    });

    test('超时与连接失败文案可区分', () {
      final timeout = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.receiveTimeout,
      );
      expect(describeApiError(timeout), contains('超时'));
    });

    test('ApiException 直接抛出时也能取到文案', () {
      expect(
        describeApiError(const ApiException(code: 409, message: '名称已存在')),
        '名称已存在',
      );
    });
  });
}
