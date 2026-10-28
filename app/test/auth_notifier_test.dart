import 'package:app/core/storage/auth_session.dart';
import 'package:app/core/storage/secure_store.dart';
import 'package:app/features/auth/application/auth_notifier.dart';
import 'package:app/features/auth/data/auth_repository.dart';
import 'package:app/features/auth/domain/token.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存态安全存储假体（避免 flutter_secure_storage 在 CI/主机环境真实落盘）。
class FakeSecureStore extends SecureStore {
  final Map<String, String> _m = <String, String>{};

  @override
  Future<AuthSession?> loadSession() async {
    final access = _m['access_token'];
    final refresh = _m['refresh_token'];
    final baseUrl = _m['base_url'];
    if (access == null || refresh == null || baseUrl == null) return null;
    return AuthSession(
      baseUrl: baseUrl,
      username: _m['username'] ?? '',
      accessToken: access,
      accessExpiresAt: int.tryParse(_m['access_expires_at'] ?? '') ?? 0,
      refreshToken: refresh,
      refreshExpiresAt: int.tryParse(_m['refresh_expires_at'] ?? '') ?? 0,
    );
  }

  @override
  Future<void> saveSession(AuthSession session) async {
    _m['access_token'] = session.accessToken;
    _m['access_expires_at'] = session.accessExpiresAt.toString();
    _m['refresh_token'] = session.refreshToken;
    _m['refresh_expires_at'] = session.refreshExpiresAt.toString();
    _m['base_url'] = session.baseUrl;
    _m['username'] = session.username;
  }

  @override
  Future<String?> readBaseUrl() async => _m['base_url'];
  @override
  Future<String?> readUsername() async => _m['username'];
  @override
  Future<void> clearAll() async => _m.clear();
}

/// 登录成功假体。
class FakeAuthRepositorySuccess extends AuthRepository {
  FakeAuthRepositorySuccess() : super();
  @override
  Future<TokenResponse> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async =>
      TokenResponse(
        accessToken: 'access-abc',
        refreshToken: 'refresh-abc',
        expiresIn: 900,
        refreshExpiresAt: AuthSession.nowSeconds() + 7 * 86400,
      );
}

void main() {
  test('AuthNotifier 初始态：未登录且未初始化', () {
    final container = ProviderContainer(
      overrides: [
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
      ],
    );
    final state = container.read(authNotifierProvider);
    expect(state.session, isNull);
    expect(state.initialized, isFalse);
    expect(state.isAuthed, isFalse);
  });

  test('login 成功：写入会话并标记已初始化', () async {
    final container = ProviderContainer(
      overrides: [
        secureStoreProvider.overrideWithValue(FakeSecureStore()),
        authRepositoryProvider
            .overrideWithValue(FakeAuthRepositorySuccess()),
      ],
    );
    final notifier = container.read(authNotifierProvider.notifier);
    await notifier.login(
      baseUrl: 'https://fb.example.com',
      username: 'admin',
      password: 'secret',
    );
    final state = container.read(authNotifierProvider);
    expect(state.initialized, isTrue);
    expect(state.session, isNotNull);
    expect(state.session!.baseUrl, 'https://fb.example.com');
    expect(state.session!.username, 'admin');
    expect(state.session!.accessToken, 'access-abc');
    // access 过期时点 ≈ now + expiresIn(900s)。
    final diff = state.session!.accessExpiresAt - AuthSession.nowSeconds();
    expect(diff >= 890 && diff <= 910, isTrue);
    expect(state.error, isNull);
  });
}
