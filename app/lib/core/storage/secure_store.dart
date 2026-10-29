import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_session.dart';

/// 令牌与身份的安全存储封装（Android Keystore，flutter_secure_storage）。
///
/// 持久化键（均为字符串值）：
///  - access_token / access_expires_at(unix 秒) / refresh_token / refresh_expires_at(unix 秒)
///  - base_url（自分发 App 指向用户自己的 fleetboard 地址）/ username
///  - saved_password / remember_enabled（M11+M12 免密登录；仅在用户勾选后写入）
///
/// 提供 load / save（整会话）/ saveAccess（刷新后仅更 access + 可选 refresh_expires_at）/
/// clearAll（**白名单删除**）/ clearSessionKeepIdentity（7 天硬墙过期：清令牌但保留 base_url + username）。
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
  static const String _kSavedPassword = 'saved_password';
  static const String _kRemember = 'remember_enabled';

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

  /// 完全清除登录态（登出 / 刷新失败 / ver 吊销）。
  ///
  /// **必须是白名单删除，不能用 `deleteAll()`。**
  /// 历史事故：登出时 `deleteAll()` 把 `base_url` 一起清掉，而 base_url 在
  /// M10.2 之后已不在登录页暴露（改址走隐藏入口），用户登出后 App 直接变成
  /// 「未配置服务器地址」，只能靠连点标题七次找回入口。同理，用户勾选过
  /// 「保存密码」的意图也应跨越一次登出继续有效——登出的是会话，不是设备授权。
  Future<void> clearAll() async {
    for (final key in <String>[
      _kAccess,
      _kAccessExp,
      _kRefresh,
      _kRefreshExp,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// 7 天硬墙过期：仅清令牌，保留 base_url + username 以便重登预填。
  Future<void> clearSessionKeepIdentity() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kAccessExp);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kRefreshExp);
  }

  // ── 免密登录（M12）────────────────────────────────────────────
  //
  // 存的是登录密码原文，加密由 Android Keystore 负责（encryptedSharedPreferences）。
  // 为什么不用 device-token：那要新增两个端点 + deviceId 生命周期管理 + 吊销接口，
  // 而两者在本机上的安全级别相近（拿到设备即拿到面板全权限），成本却差一个量级。
  //
  // 三条硬约束（缺一条就等于把密码永久留在设备上）：
  //  1) 只有用户显式勾选才写；默认不勾。
  //  2) 改服务器地址即清空——旧密码对新地址毫无意义，留着只会误导自动填充。
  //  3) 连续 3 次登录失败即清空——大概率是密码已改，留着会一直失败。

  Future<String?> readSavedPassword() => _storage.read(key: _kSavedPassword);

  Future<bool> readRememberEnabled() async =>
      (await _storage.read(key: _kRemember)) == '1';

  Future<void> savePassword(String password) async {
    await _storage.write(key: _kSavedPassword, value: password);
    await _storage.write(key: _kRemember, value: '1');
  }

  Future<void> clearSavedPassword() async {
    await _storage.delete(key: _kSavedPassword);
    await _storage.delete(key: _kRemember);
  }

  /// 用户主动取消勾选：只删密码，不碰其它键。
  Future<void> setRememberEnabled(bool enabled) async {
    if (enabled) {
      await _storage.write(key: _kRemember, value: '1');
      return;
    }
    await clearSavedPassword();
  }
}

/// 安全存储单例（令牌 / 身份）。
final secureStoreProvider = Provider<SecureStore>((ref) => const SecureStore());
