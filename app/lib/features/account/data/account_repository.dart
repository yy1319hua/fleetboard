import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../domain/account_identity.dart';

/// 账户仓储（鉴权 dio）。
///
/// 契约（对照 internal/api/auth_handlers.go 核实）：
/// - `POST /api/auth/change-username` 入参 `{new_username, current_password}`，
///   成功 200 回 `{id, username}`。**不重签 token、不动 ver**：
///   JWT 里没有用户名，改名与鉴权无关，客户端也就绝不能改成「重新登录」。
/// - 失败语义：409 = 该用户名已被占用（含大小写不同的同名）；401 = 当前密码错
///   或用户已不存在；400 = 格式不对 / 与当前用户名相同。
/// - `GET /api/me` 回 `{id, username}`，是显示名的权威来源。
class AccountRepository {
  AccountRepository(this._dio);

  final Dio _dio;

  Future<AccountIdentity> me() async {
    final resp = await _dio.get<dynamic>('/api/me');
    return unwrap<AccountIdentity>(resp.data, AccountIdentity.fromJson);
  }

  Future<AccountIdentity> changeUsername({
    required String newUsername,
    required String currentPassword,
  }) async {
    final resp = await _dio.post<dynamic>(
      '/api/auth/change-username',
      data: <String, String>{
        'new_username': newUsername.trim(),
        'current_password': currentPassword,
      },
    );
    return unwrap<AccountIdentity>(resp.data, AccountIdentity.fromJson);
  }
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(jsonDioProvider)),
);
