import 'package:freezed_annotation/freezed_annotation.dart';

part 'token.freezed.dart';
part 'token.g.dart';

/// 登录请求体。
///
/// 对齐后端 `loginRequest`：仅 {username, password}。base_url 是自分发客户端的
/// 服务端基址（见 M9.2 契约差异），不进登录 body，由客户端另行存储并用于拼装 API 地址。
@freezed
class LoginRequest with _$LoginRequest {
  const factory LoginRequest({
    required String username,
    required String password,
  }) = _LoginRequest;

  factory LoginRequest.fromJson(Map<String, dynamic> json) =>
      _$LoginRequestFromJson(json);

  Map<String, dynamic> toJson() => _$LoginRequestToJson(this);
}

/// 令牌响应体（登录与刷新共用）。
///
/// 对齐后端 `tokenResponse`：
///  - access_token：访问令牌。
///  - refresh_token：**仅登录时返回**；刷新时不回传（omitempty），客户端保留旧值。
///  - expires_in：access 有效期（秒）。后端不回传 access_expires_at，由客户端用
///    now + expires_in 派生绝对过期时点（见 [AuthSession.computeAccessExpiresAt]）。
///  - refresh_expires_at：refresh 7 天硬墙绝对时点（unix 秒）；刷新时由服务端回显同一值。
@freezed
class TokenResponse with _$TokenResponse {
  const factory TokenResponse({
    @JsonKey(name: 'access_token') required String accessToken,
    @JsonKey(name: 'refresh_token') String? refreshToken,
    @JsonKey(name: 'expires_in') required int expiresIn,
    @JsonKey(name: 'refresh_expires_at') required int refreshExpiresAt,
  }) = _TokenResponse;

  factory TokenResponse.fromJson(Map<String, dynamic> json) =>
      _$TokenResponseFromJson(json);
}
