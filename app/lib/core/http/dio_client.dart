import 'package:dio/dio.dart';

import 'auth_interceptor.dart';

/// dio 薄封装实例（M9.1 骨架）。
///
/// M9.2 落地：
///  - baseUrl 来自 SecureStore 基址；
///  - 超时分级（普通 GET 15s / SSH 类 120s，见 M9 方案 §2.5）；
///  - 仅幂等 GET 重试 2 次；写操作注入 X-Client-Op-Id 不重试（WriteGuard）。
Dio createDio({required Future<String?> Function() getToken}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      // baseUrl: '...' // M9.2 从 SecureStore 注入
    ),
  );
  dio.interceptors.add(AuthInterceptor(getToken));
  return dio;
}
