import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../domain/token.dart';

/// 认证仓储：登录（无鉴权，自拼 base_url）。
///
/// 使用"裸" dio（createPlainDio），不走 Bearer 拦截器，避免登录请求误入 401 刷新回路。
/// refresh 不在此处（由 AuthNotifier + RefreshGate 单飞处理，见 application 层）。
class AuthRepository {
  AuthRepository({Dio? dio}) : _dio = dio ?? createPlainDio();

  final Dio _dio;

  Future<TokenResponse> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final normalized =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final resp = await _dio.post(
      '$normalized/api/login',
      data: LoginRequest(username: username, password: password).toJson(),
    );
    return unwrap<TokenResponse>(resp.data, TokenResponse.fromJson);
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository());
