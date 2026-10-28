/// 当前登录会话的不可变快照（与 SecureStore 持久化结构一一对应）。
///
/// 时间统一以 **unix 秒（int）** 持久化（M9.2 约束），避免时区/序列化歧义。
class AuthSession {
  const AuthSession({
    required this.baseUrl,
    required this.username,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  });

  final String baseUrl;
  final String username;
  final String accessToken;
  final int accessExpiresAt; // unix 秒：access 过期绝对时点
  final String refreshToken;
  final int refreshExpiresAt; // unix 秒：refresh 7 天硬墙绝对时点

  static int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 由 refresh 响应派生 access 过期时点：now + expires_in（秒）。
  static int computeAccessExpiresAt(int expiresIn) =>
      nowSeconds() + expiresIn;

  int get accessRemainingSeconds => accessExpiresAt - nowSeconds();
  bool get isAccessExpired => accessRemainingSeconds <= 0;

  int get refreshRemainingSeconds => refreshExpiresAt - nowSeconds();
  bool get isRefreshExpired => refreshRemainingSeconds <= 0;

  /// 7 天硬墙进入 24h 预警窗口。
  bool get isRefreshExpiringSoon => refreshRemainingSeconds <= 24 * 3600;
}
