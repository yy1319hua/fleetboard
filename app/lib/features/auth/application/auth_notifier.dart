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
    } on Object catch (e) {
      state = state.copyWith(loading: false, error: resolveLoginError(e));
    }
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
