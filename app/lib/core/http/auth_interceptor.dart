import 'package:dio/dio.dart';

import '../errors/api_exception.dart';

/// 鉴权拦截器（M9.2 落地）。
///
/// 职责：
///  1) onRequest：从 SecureStore 读取 base_url 注入请求基址，读取 access token 注入
///     `Authorization: Bearer`；无 token 时不注入（登录/refresh 场景安全）。
///  2) onError：捕获 401（ApiException.code==401 或响应态 401），经 [onUnauthorized]
///     单飞刷新令牌后，用新令牌重放原请求一次；刷新失败则向上传播 401，由登录页/路由兜底。
///
/// 单飞由 [onUnauthorized] 内部（RefreshGate）保证，本拦截器只负责"触发 + 重放"。
class AuthInterceptor extends Interceptor {
  AuthInterceptor(
    this._dio,
    this._getToken,
    this._getBaseUrl,
    this._onUnauthorized,
  );

  final Dio _dio;
  final Future<String?> Function() _getToken;
  final Future<String?> Function() _getBaseUrl;
  final Future<void> Function() _onUnauthorized;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final baseUrl = await _getBaseUrl();
    if (baseUrl != null && baseUrl.isNotEmpty) {
      options.baseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;
    }
    final token = await _getToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final isUnauthorized = err.response?.statusCode == 401 ||
        (err.error is ApiException &&
            (err.error as ApiException).code == 401);
    if (!isUnauthorized) {
      handler.next(err);
      return;
    }
    // 已重放过仍 401：直接放行，由上层（登录页/路由）处理登出。
    if (err.requestOptions.extra['_refreshed'] == true) {
      handler.next(err);
      return;
    }
    try {
      await _onUnauthorized();
    } catch (_) {
      // 刷新失败：传播原始 401，不重放。onUnauthorized 内部已负责清令牌/回登录。
      handler.next(err);
      return;
    }
    // 刷新成功：用新令牌重放原请求一次。
    final opts = err.requestOptions;
    opts.extra = Map<String, dynamic>.from(opts.extra)..['_refreshed'] = true;
    final token = await _getToken();
    if (token != null && token.isNotEmpty) {
      opts.headers['Authorization'] = 'Bearer $token';
    }
    try {
      final response = await _dio.fetch<dynamic>(opts);
      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
