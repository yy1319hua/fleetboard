import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../storage/secure_store.dart';
import '../auth_notifier.dart';
import 'auth_interceptor.dart';
import 'dio_client.dart';

/// 鉴权 dio：注入 base_url + Bearer，401 经 AuthNotifier 单飞刷新后重放。
///
/// 依赖 AuthNotifier（仅取其 notifier 调 ensureFresh / onRefreshFailed）与 SecureStore。
/// 无环：AuthNotifier 不依赖本 provider（其刷新用内部裸 dio）。
final dioProvider = Provider<Dio>((ref) {
  final store = ref.watch(secureStoreProvider);
  final auth = ref.watch(authNotifierProvider.notifier);
  final dio = createDio(
    getToken: store.readAccessToken,
    getBaseUrl: store.readBaseUrl,
    onUnauthorized: () async {
      try {
        await auth.ensureFresh();
      } on Object {
        // 刷新失败（ver 吊销 / 网络）：清令牌回登录，再向上传播 401。
        await auth.onRefreshFailed();
        rethrow;
      }
    },
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});
