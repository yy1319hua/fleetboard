import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../storage/secure_store.dart';
import '../../features/auth/application/auth_notifier.dart';
import 'dio_client.dart';

/// base_url 解析：已存值优先（refresh 续期绑死签发域名），空则回退编译期注入值。
///
/// 首启 bootstrap 尚未物化、或老版本残留空值时，请求也不会打到空基址（M10.2）。
Future<String?> _resolveBaseUrl(SecureStore store) async {
  final stored = await store.readBaseUrl();
  return (stored == null || stored.isEmpty) ? AppConfig.defaultBaseUrl : stored;
}

/// 401 的统一处置：先单飞刷新，失败即清令牌回登录并把错误抛回去。
///
/// 抽成函数是因为三个鉴权档位（json/stream）共用同一套语义；
/// 复制粘贴会让「流式实例忘记 onRefreshFailed」这类错误静默存在。
Future<void> Function() _unauthorizedHandler(AuthNotifier auth) =>
    () async {
      try {
        await auth.ensureFresh();
      } on Object {
        await auth.onRefreshFailed();
        rethrow;
      }
    };

/// 鉴权 dio（JSON CRUD 档）：10/20/20s，401 刷新后允许重放一次。
///
/// 依赖 AuthNotifier（仅取其 notifier 调 ensureFresh / onRefreshFailed）与 SecureStore。
/// 无环：AuthNotifier 不依赖本 provider（其刷新用内部裸 dio）。
final jsonDioProvider = Provider<Dio>((ref) {
  final store = ref.watch(secureStoreProvider);
  final auth = ref.watch(authNotifierProvider.notifier);
  final dio = createProfileDio(
    DioProfile.json,
    getToken: store.readAccessToken,
    getBaseUrl: () => _resolveBaseUrl(store),
    onUnauthorized: _unauthorizedHandler(auth),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

/// 鉴权 dio（流式档）：上传 / 下载 / SSE。无接收超时，401 不重放。
///
/// 上传下载都是「长时间单向传输」，用 CRUD 档的 20s 接收超时会在大文件上误杀；
/// 真正的死连接由 [StreamWatchdog]（90s 无字节增长）判定。
final streamDioProvider = Provider<Dio>((ref) {
  final store = ref.watch(secureStoreProvider);
  final auth = ref.watch(authNotifierProvider.notifier);
  final dio = createProfileDio(
    DioProfile.stream,
    getToken: store.readAccessToken,
    getBaseUrl: () => _resolveBaseUrl(store),
    onUnauthorized: _unauthorizedHandler(auth),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

/// 无鉴权 dio：登录 / refresh。只挂信封解包，不进入 401 刷新回路。
final plainDioProvider = Provider<Dio>((ref) {
  final dio = createProfileDio(DioProfile.plain);
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

/// 探活 dio：health / 升级状态轮询。3s 全超时，不解析信封。
///
/// 升级期间面板会停机，超时必须短——否则「发现服务已停」要等 15s，
/// App 的升级进度会长时间停在「等待服务重启」。
final probeDioProvider = Provider<Dio>((ref) {
  final store = ref.watch(secureStoreProvider);
  final dio = createProfileDio(
    DioProfile.probe,
    getBaseUrl: () => _resolveBaseUrl(store),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

/// 旧名保留：等价于 [jsonDioProvider]，供既有 repository 平滑迁移。
final dioProvider = jsonDioProvider;
