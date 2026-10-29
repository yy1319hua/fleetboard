import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/http/envelope.dart';
import '../../../core/http/providers.dart';
import '../../auth/domain/token.dart';
import '../domain/settings.dart';

/// 设置与安全仓储（鉴权 dio）。
///
/// 契约要点（2026-10-29 对照后端核实）：
/// - `PUT /api/settings` 请求体为**扁平** `{key: value}`，只写传入的 key（merge 语义），
///   未知 key 返 400；敏感项若以 `****` 开头或为空则被服务端跳过。
///   → 客户端因此有两个约束：① 只提交用户真正改过的 key；② 掩码值永不回传。
/// - `POST /api/settings/test-channel` 的 `token` 可传**未保存**的新值，空则测已存值。
/// - `POST /api/auth/change-password` 成功后返回**新的 token 对**（旧 refresh 全灭），
///   调用方必须立刻落盘，否则下一次刷新会被判无效而踢回登录页。
class SettingsRepository {
  SettingsRepository(this._dio);

  final Dio _dio;

  Future<SettingsResponse> getSettings() async {
    final resp = await _dio.get<dynamic>('/api/settings');
    return unwrap<SettingsResponse>(resp.data, SettingsResponse.fromJson);
  }

  /// 只提交改动项。空 map 直接返回，不发无意义请求。
  Future<void> updateSettings(Map<String, String> updates) async {
    if (updates.isEmpty) return;
    await _dio.put<dynamic>('/api/settings', data: updates);
  }

  /// 发送测试推送。[token] 非空时用该未保存值，为空则用服务端已存值。
  Future<void> testChannel({String? token}) async {
    final trimmed = token?.trim() ?? '';
    await _dio.post<dynamic>(
      '/api/settings/test-channel',
      data: trimmed.isEmpty
          ? <String, dynamic>{}
          : <String, dynamic>{'token': trimmed},
    );
  }

  /// 注销所有会话（ver 自增，本端与其他端全部下线）。调用后本机须自行登出。
  Future<void> revokeSessions() async {
    await _dio.post<dynamic>('/api/settings/actions/revoke-sessions');
  }

  Future<TokenResponse> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final resp = await _dio.post<dynamic>(
      '/api/auth/change-password',
      data: <String, String>{
        'old_password': oldPassword,
        'new_password': newPassword,
      },
    );
    return unwrap<TokenResponse>(resp.data, TokenResponse.fromJson);
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(dioProvider)),
);
