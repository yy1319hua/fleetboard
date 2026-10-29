import 'package:dio/dio.dart';

import '../errors/api_exception.dart';

/// 信封解包：从统一响应体 `{code,msg,data}` 取出 data 并反序列化为 T。
///
/// 约定：调用前响应已通过 [EnvelopeInterceptor] 校验；此处再做一次防御性 code 检查。
T unwrap<T>(
  dynamic raw,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw is! Map<String, dynamic>) {
    throw const ApiException(message: '响应格式异常');
  }
  final code = raw['code'] as int? ?? 0;
  if (code != 0) {
    throw ApiException(
      code: code,
      message: raw['msg'] as String? ?? '请求失败',
    );
  }
  final data = raw['data'];
  if (data is Map<String, dynamic>) return fromJson(data);
  // 极少数端点可能返回非对象 data（本工程暂不涉及），直接按 T 返回。
  return data as T;
}

/// 列表型信封解包：`data` 为数组时逐项反序列化。
///
/// 与 [unwrap] 分开是因为 `data` 既可能是对象也可能是数组，用同一个泛型
/// 强转会得到运行时类型错误，而不是可读的失败信息。
List<T> unwrapList<T>(
  dynamic raw,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (raw is! Map<String, dynamic>) {
    throw const ApiException(message: '响应格式异常');
  }
  final code = raw['code'] as int? ?? 0;
  if (code != 0) {
    throw ApiException(
      code: code,
      message: raw['msg'] as String? ?? '请求失败',
    );
  }
  final data = raw['data'];
  if (data == null) return <T>[];
  if (data is! List<dynamic>) {
    throw const ApiException(message: '响应格式异常：期望列表');
  }
  return data
      .whereType<Map<String, dynamic>>()
      .map(fromJson)
      .toList(growable: false);
}

/// 响应拦截器：统一处理信封与 HTTP 状态。
///
/// - 2xx 且 code==0：放行（resp.data 仍为完整信封，由 [unwrap] 取 data）。
/// - 2xx 但 code!=0 或非 2xx：reject 为携带 [ApiException] 的 DioException。
/// - 无响应（网络层失败）：放行给 onError，由调用方按网络错误提示。
class EnvelopeInterceptor extends Interceptor {
  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      final body = response.data;
      if (body is Map<String, dynamic>) {
        final code = body['code'] as int? ?? 0;
        if (code != 0) {
          // 不放行 silent：让后续 AuthInterceptor.onError 仍能捕获 401 触发刷新。
          handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              response: response,
              error: ApiException(
                code: code,
                message: body['msg'] as String? ?? '请求失败',
              ),
            ),
          );
          return;
        }
      }
      handler.next(response);
      return;
    }
    // 非 2xx：解析信封文案后 reject。
    final body = response.data;
    var code = status;
    var msg = '服务异常';
    if (body is Map<String, dynamic>) {
      code = (body['code'] as int?) ?? status;
      msg = (body['msg'] as String?) ?? msg;
    }
    handler.reject(
      DioException(
        requestOptions: response.requestOptions,
        response: response,
        error: ApiException(code: code, message: msg),
      ),
    );
  }
}

/// 创建"裸" dio：仅挂 [EnvelopeInterceptor]，不注入鉴权头、不触发刷新。
///
/// 用于登录（无 token）与 refresh（凭 refresh_token，独立端点）等无需 Bearer 的请求，
/// 避免 refresh 自身再次进入 401 刷新回路。所有状态码均放行给拦截器统一处理。
Dio createPlainDio() {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (_) => true,
    ),
  );
  dio.interceptors.add(EnvelopeInterceptor());
  return dio;
}
