import 'package:dio/dio.dart';

/// 鉴权拦截器（M9.1 骨架）。
///
/// M9.2 落地：从 SecureStore 读取 access token 注入 `Authorization: Bearer`；
/// 捕获 401 后触发 [RefreshGate.ensureFresh] 单飞刷新并重试原请求。
/// 本步仅骨架：[_getToken] 由 M9.2 接入 SecureStore。
class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._getToken);

  final Future<String?> Function() _getToken;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _getToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  // M9.2: @override
  // Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
  //   if (err.response?.statusCode == 401) {
  //     await RefreshGate(getToken: _getToken, doRefresh: ...).ensureFresh();
  //     // 用新 token 重试原请求
  //   }
  //   handler.next(err);
  // }
}
