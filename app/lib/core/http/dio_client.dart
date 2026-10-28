import 'package:dio/dio.dart';

import 'auth_interceptor.dart';
import 'envelope.dart';

/// 鉴权 dio 实例（M9.2 落地）。
///
/// 拦截器顺序（影响 onError 回放）：[EnvelopeInterceptor, AuthInterceptor]。
///  - EnvelopeInterceptor：统一解包信封、将非成功响应 reject 为 ApiException。
///  - AuthInterceptor：注入 base_url + Bearer；捕获 401 经 RefreshGate 单飞刷新后重放。
///
/// base_url 来自 SecureStore（自分发 App 指向用户自己的 fleetboard 地址），在 onRequest
/// 动态注入，兼容冷启动恢复后切换账号场景。
/// 超时分级（M9 方案 §2.5）：普通 GET 15s；SSH 类长任务由调用方自行覆盖。
Dio createDio({
  required Future<String?> Function() getToken,
  required Future<String?> Function() getBaseUrl,
  required Future<void> Function() onUnauthorized,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (_) => true,
    ),
  );
  dio.interceptors.add(EnvelopeInterceptor());
  dio.interceptors
      .add(AuthInterceptor(dio, getToken, getBaseUrl, onUnauthorized));
  return dio;
}
