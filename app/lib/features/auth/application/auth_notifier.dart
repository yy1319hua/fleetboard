import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/http/envelope.dart';
import '../../../core/http/refresh_gate.dart';
import '../../../core/storage/auth_session.dart';
import '../../../core/storage/secure_store.dart';
import '../data/auth_repository.dart';
import '../domain/token.dart';

part 'auth_notifier.freezed.dart';

/// 7 天硬墙状态（供 UI 决定提示/登出）。
enum RefreshWallStatus { ok, warn, expired }

/// 鉴权状态（M9.2）。
@freezed
class AuthState with _$AuthState {
  const AuthState._();

  const factory AuthState({
    /// 冷启动 tryRestore 是否已完成。
    @Default(false) bool initialized,

    /// 当前会话；null = 未登录。
    AuthSession? session,

    /// 最近一次登录错误文案（中文）。
    String? error,
    @Default(false) bool loading,
  }) = _AuthState;

  bool get isAuthed => session != null;
}

/// access 临近过期阈值（秒）：剩 <60s 触发预刷新。
const int _accessPreemptThreshold = 60;

/// 鉴权状态机 + JWT 静默续期编排（M9.2 核心）。
///
/// 三触发点共用 [RefreshGate] 单飞：① 冷启动 tryRestore 预刷新；② AppLifecycle resumed；
/// ③ dio401 重放（见 core/http/auth_interceptor 经 [ensureFresh] 调用）。
/// 不做定时轮询。
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier({
    required this.secureStore,
    required this.authRepository,
  }) : super(const AuthState());

  final SecureStore secureStore;
  final AuthRepository authRepository;
  final RefreshGate _gate = RefreshGate();
  final Dio _refreshDio = createPlainDio();

  /// 最近一次登录失败是否是「凭据被服务端拒绝」（HTTP 401）。
  ///
  /// 免密登录的「连续失败 3 次就清密码」只认这一类：断网时连点三次就把本机密码
  /// 删掉，等于让用户在飞机上丢掉自动填充——那不是密码失效，只是网络不可达。
  bool lastLoginFailureWasCredentialRejection = false;

  /// 单飞刷新；三触发点统一入口。
  Future<void> ensureFresh() => _gate.run(_refreshNow);

  /// 生效基址（M10.2）：已存值 > dart-define > 内置常量，统一在此规范化。
  ///
  /// 已存值优先是硬要求：refresh 续期绑死签发时的域名，若被编译期注入值反向覆盖，
  /// 老用户会拿旧 token 去新域名换新 token，必然 401 掉登录。
  Future<String> effectiveBaseUrl() async {
    final stored = await secureStore.readBaseUrl();
    return AppConfig.normalize(
      (stored != null && stored.isNotEmpty) ? stored : AppConfig.defaultBaseUrl,
    );
  }

  /// 实际刷新：凭 refresh_token 换新 access，写入 SecureStore。
  Future<void> _refreshNow() async {
    final refreshToken = await secureStore.readRefreshToken();
    if (refreshToken == null) {
      throw const ApiException(message: '缺少刷新令牌');
    }
    final normalized = await effectiveBaseUrl();
    final resp = await _refreshDio.post(
      '$normalized/api/refresh',
      data: {'refresh_token': refreshToken},
    );
    final token = unwrap<TokenResponse>(resp.data, TokenResponse.fromJson);
    await secureStore.saveAccess(
      accessToken: token.accessToken,
      accessExpiresAt: AuthSession.computeAccessExpiresAt(token.expiresIn),
      refreshExpiresAt: token.refreshExpiresAt,
    );
  }

  /// 冷启动：从 SecureStore 恢复会话；若 access 临近过期先单飞刷新；
  /// 若 7 天硬墙已过期则清令牌（保留身份）回登录。
  Future<void> tryRestore() async {
    final session = await secureStore.loadSession();
    if (session == null) {
      state = state.copyWith(initialized: true);
      return;
    }
    AuthSession effective = session;
    if (session.accessExpiresAt - AuthSession.nowSeconds() <
        _accessPreemptThreshold) {
      try {
        await ensureFresh();
        final reloaded = await secureStore.loadSession();
        if (reloaded != null) effective = reloaded;
      } on Object {
        // 刷新失败（ver 吊销/网络）：硬墙过期则清令牌；否则保留会话稍后重试。
        if (session.isRefreshExpired) {
          await secureStore.clearSessionKeepIdentity();
          state = state.copyWith(initialized: true);
          return;
        }
      }
    }
    if (effective.isRefreshExpired) {
      await secureStore.clearSessionKeepIdentity();
      state = state.copyWith(initialized: true);
      return;
    }
    state = state.copyWith(initialized: true, session: effective);
  }

  /// onResumed 触发：刷新 near-expiry access；评估 7 天硬墙。
  /// 返回状态供 UI 提示（warn）或登出（expired）。
  Future<RefreshWallStatus> ensureFreshAccessOnResume() async {
    final session = state.session;
    if (session == null) return RefreshWallStatus.ok;
    if (session.isRefreshExpired) {
      await secureStore.clearSessionKeepIdentity();
      state = state.copyWith(session: null);
      return RefreshWallStatus.expired;
    }
    if (session.isRefreshExpiringSoon) {
      if (session.accessExpiresAt - AuthSession.nowSeconds() <
          _accessPreemptThreshold) {
        try {
          await ensureFresh();
          final reloaded = await secureStore.loadSession();
          if (reloaded != null) state = state.copyWith(session: reloaded);
        } on Object {
          // 网络抖动：保留会话，下次 onResumed/401 再试。
        }
      }
      return RefreshWallStatus.warn;
    }
    if (session.accessExpiresAt - AuthSession.nowSeconds() <
        _accessPreemptThreshold) {
      try {
        await ensureFresh();
        final reloaded = await secureStore.loadSession();
        if (reloaded != null) state = state.copyWith(session: reloaded);
      } on Object {
        // 保留会话。
      }
    }
    return RefreshWallStatus.ok;
  }

  /// 登录：用户名 + 密码（M10.2 起登录页不再手填地址）。
  ///
  /// 基址取自 [effectiveBaseUrl]（已存值 > 内置默认）。成功后写入会话并跳总览（路由重定向）。
  Future<void> login({
    required String username,
    required String password,
  }) async {
    lastLoginFailureWasCredentialRejection = false;
    state = state.copyWith(loading: true, error: null);
    try {
      final baseUrl = await effectiveBaseUrl();
      // 未配置地址（本地调试未传 --dart-define、或包构建异常）时不发必败请求。
      if (baseUrl.isEmpty) {
        state = state.copyWith(
          loading: false,
          error: '客户端未配置服务器地址，请安装正式发布版本',
        );
        return;
      }
      final token = await authRepository.login(
        baseUrl: baseUrl,
        username: username,
        password: password,
      );
      final session = AuthSession(
        baseUrl: baseUrl,
        username: username,
        accessToken: token.accessToken,
        accessExpiresAt: AuthSession.computeAccessExpiresAt(token.expiresIn),
        refreshToken: token.refreshToken ?? '',
        refreshExpiresAt: token.refreshExpiresAt,
      );
      await secureStore.saveSession(session);
      state = state.copyWith(
        loading: false,
        session: session,
        error: null,
        initialized: true,
      );
    } on Object catch (raw) {
      final error = _unwrapEnvelope(raw);
      lastLoginFailureWasCredentialRejection =
          error is ApiException && error.code == 401;
      state = state.copyWith(loading: false, error: resolveLoginError(error));
    }
  }

  /// 把 `DioException(error: ApiException)` 里的信封错误取出来。
  ///
  /// 为什么必须拆这一层：plain dio 的 [EnvelopeInterceptor] 把业务失败 reject 成
  /// `DioException`，而 [resolveLoginError] 只认 [ApiException]。少了这一步，
  /// 输错密码会显示「无法连接服务器，请检查网络」——把一次明确的凭据错误说成
  /// 网络问题，用户会去重装 App、换网络，而真正该做的是核对密码。
  static Object _unwrapEnvelope(Object error) {
    if (error is DioException) {
      final inner = error.error;
      if (inner is ApiException) return inner;
    }
    return error;
  }

  /// 用服务端新签发的 token 对替换本地会话（M11：改密后调用）。
  ///
  /// 改密会让 `ver` 自增，旧 refresh 立即失效；若不同步落盘，下一次静默续期
  /// 必然失败 → 用户被踢回登录页，而他会以为「改完密码就被强制下线」。
  Future<void> applyTokenPair(TokenResponse token) async {
    final current = state.session;
    if (current == null) return;
    final next = AuthSession(
      baseUrl: current.baseUrl,
      username: current.username,
      accessToken: token.accessToken,
      accessExpiresAt: AuthSession.computeAccessExpiresAt(token.expiresIn),
      refreshToken: token.refreshToken ?? '',
      refreshExpiresAt: token.refreshExpiresAt,
    );
    await secureStore.saveSession(next);
    state = state.copyWith(session: next);
  }

  /// 改名成功后刷新本地显示名（M11）。
  ///
  /// 只同步 `username` 这一项：JWT claims 里只有 uid/typ/ver，不包含用户名，
  /// 所以改名与鉴权无关——**不重签 token、不 bump ver、不重新登录**。
  /// 令牌原样保留，顺手用同一份快照重写一遍 SecureStore，让冷启动也能显示新名字。
  Future<void> applyUsername(String username) async {
    final current = state.session;
    final next = username.trim();
    if (current == null || next.isEmpty || current.username == next) return;
    final updated = AuthSession(
      baseUrl: current.baseUrl,
      username: next,
      accessToken: current.accessToken,
      accessExpiresAt: current.accessExpiresAt,
      refreshToken: current.refreshToken,
      refreshExpiresAt: current.refreshExpiresAt,
    );
    await secureStore.saveSession(updated);
    state = state.copyWith(session: updated);
  }

  /// 登出：清全部令牌与身份，路由重定向回登录。
  Future<void> logout() async {
    await secureStore.clearAll();
    state = const AuthState(initialized: true);
  }

  /// 刷新失败兜底（由 dio401 路径的 onUnauthorized catch 调用）：清全部令牌回登录。
  Future<void> onRefreshFailed() async {
    await secureStore.clearAll();
    state = const AuthState(initialized: true);
  }
}

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(
    secureStore: ref.watch(secureStoreProvider),
    authRepository: ref.watch(authRepositoryProvider),
  );
});
