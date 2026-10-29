import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_session.dart';

/// 令牌与身份的安全存储封装（Android Keystore，flutter_secure_storage）。
///
/// 持久化键（均为字符串值）：
///  - access_token / access_expires_at(unix 秒) / refresh_token / refresh_expires_at(unix 秒)
///  - base_url（自分发 App 指向用户自己的 fleetboard 地址）/ username
///
/// 提供 load / save（整会话）/ saveAccess（刷新后仅更 access + 可选 refresh_expires_at）/
/// clearAll / clearSessionKeepIdentity（7 天硬墙过期：清令牌但保留 base_url + username）。
class SecureStore {
  const SecureStore();

  static const _storage = FlutterSecureStorage(
    // Android：硬件支持时强加密（encryptedSharedPreferences 仅 API 23+ 可用，会自动降级）。
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String _kAccess = 'access_token';
  static const String _kAccessExp = 'access_expires_at';
  static const String _kRefresh = 'refresh_token';
  static const String _kRefreshExp = 'refresh_expires_at';
  static const String _kBaseUrl = 'base_url';
  static const String _kUsername = 'username';

  /// 仅当关键令牌齐全时返回会话；否则返回 null（视为未登录）。
  Future<AuthSession?> loadSession() async {
    final access = await _storage.read(key: _kAccess);
    final refresh = await _storage.read(key: _kRefresh);
    final baseUrl = await _storage.read(key: _kBaseUrl);
    if (access == null || refresh == null || baseUrl == null) return null;
    return AuthSession(
      baseUrl: baseUrl,
      username: await _storage.read(key: _kUsername) ?? '',
      accessToken: access,
      accessExpiresAt:
          int.tryParse(await _storage.read(key: _kAccessExp) ?? '') ?? 0,
      refreshToken: refresh,
      refreshExpiresAt:
          int.tryParse(await _storage.read(key: _kRefreshExp) ?? '') ?? 0,
    );
  }

  /// 整会话写入（登录成功时）。
  Future<void> saveSession(AuthSession session) async {
    await _storage.write(key: _kAccess, value: session.accessToken);
    await _storage.write(
      key: _kAccessExp,
      value: session.accessExpiresAt.toString(),
    );
    await _storage.write(key: _kRefresh, value: session.refreshToken);
    await _storage.write(
      key: _kRefreshExp,
      value: session.refreshExpiresAt.toString(),
    );
    await _storage.write(key: _kBaseUrl, value: session.baseUrl);
    await _storage.write(key: _kUsername, value: session.username);
  }

  /// 刷新后写入新 access（refresh 响应不回传 refresh_token，保留旧值；
  /// refresh_expires_at 由服务端回显同一时点，幂等写入）。
  Future<void> saveAccess({
    required String accessToken,
    required int accessExpiresAt,
    int? refreshExpiresAt,
  }) async {
    await _storage.write(key: _kAccess, value: accessToken);
    await _storage.write(
      key: _kAccessExp,
      value: accessExpiresAt.toString(),
    );
    if (refreshExpiresAt != null) {
      await _storage.write(
        key: _kRefreshExp,
        value: refreshExpiresAt.toString(),
      );
    }
  }

  Future<String?> readAccessToken() => _storage.read(key: _kAccess);
  Future<String?> readRefreshToken() => _storage.read(key: _kRefresh);
  Future<String?> readBaseUrl() => _storage.read(key: _kBaseUrl);
  Future<String?> readUsername() => _storage.read(key: _kUsername);

  /// 单独写 base_url（M10.2：bootstrap 物化默认地址、隐藏入口改址）。
  ///
  /// 不触碰令牌与用户名：改址后若 token 仍在，[loadSession] 语义不变，
  /// 但 refresh 续期会指向新域名（因此改址入口内置 /api/health 探测把关）。
  Future<void> writeBaseUrl(String baseUrl) =>
      _storage.write(key: _kBaseUrl, value: baseUrl);

  /// 完全清除（登出 / 刷新失败 / ver 吊销）。
  Future<void> clearAll() => _storage.deleteAll();

  /// 7 天硬墙过期：仅清令牌，保留 base_url + username 以便重登预填。
  Future<void> clearSessionKeepIdentity() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kAccessExp);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kRefreshExp);
  }
}

/// 安全存储单例（令牌 / 身份）。
final secureStoreProvider = Provider<SecureStore>((ref) => const SecureStore());
