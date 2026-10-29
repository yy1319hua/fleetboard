import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../auth/application/auth_notifier.dart';
import '../data/account_repository.dart';
import '../domain/account_identity.dart';

/// 改名表单的提交态。
class AccountState {
  const AccountState({
    this.submitting = false,
    this.fieldError,
    this.error,
    this.changedUsername,
  });

  /// 请求在途。
  final bool submitting;

  /// 就地校验错误（格式 / 与当前用户名相同），挂在输入框上。
  final String? fieldError;

  /// 整表错误（服务端拒绝 / 网络），显示在按钮上方。
  final String? error;

  /// 本次改名成功的显示名（成功后页面据此提示）。
  final String? changedUsername;

  AccountState copyWith({
    bool? submitting,
    String? fieldError,
    String? error,
    String? changedUsername,
  }) {
    return AccountState(
      submitting: submitting ?? this.submitting,
      fieldError: fieldError,
      error: error,
      changedUsername: changedUsername ?? this.changedUsername,
    );
  }
}

/// 改名编排：先就地校验 → 发请求 → 用 `/api/me` 刷新显示名。
class AccountNotifier extends StateNotifier<AccountState> {
  AccountNotifier(this._repository, this._auth) : super(const AccountState());

  final AccountRepository _repository;
  final AuthNotifier _auth;

  /// 打开表单前清一次，避免上一次的报错残留成「我一进来就错了」。
  void reset() => state = const AccountState();

  /// 改名。返回 true 表示成功。
  Future<bool> changeUsername({
    required String newUsername,
    required String currentPassword,
    required String currentUsername,
  }) async {
    final value = newUsername.trim();
    // 明显非法的输入不发请求：既省一次往返，也让用户当场看到该怎么改。
    final localError = validateUsernameInput(
      value,
      currentUsername: currentUsername,
    );
    if (localError != null) {
      state = AccountState(fieldError: localError);
      return false;
    }
    if (currentPassword.isEmpty) {
      state = const AccountState(error: '请输入当前密码以确认是本人操作');
      return false;
    }

    state = const AccountState(submitting: true);
    try {
      final changed = await _repository.changeUsername(
        newUsername: value,
        currentPassword: currentPassword,
      );
      // 显示名以 `/api/me` 为准：改名响应与本地快照都可能落后一步，
      // 而「我现在叫什么」的唯一事实在库里。这一步失败不影响改名结果，
      // 退回到改名响应里的名字即可。
      var display = changed.username;
      try {
        final me = await _repository.me();
        if (me.username.isNotEmpty) display = me.username;
      } on Object {
        // 忽略：改名已经成功，不必因为刷新显示名失败而报错。
      }
      // 只同步显示名：不重签 token、不 bump ver、不重新登录。
      await _auth.applyUsername(display);
      state = AccountState(changedUsername: display);
      return true;
    } on Object catch (e) {
      state = AccountState(error: describeChangeUsernameError(e));
      return false;
    }
  }
}

/// 改名失败的文案分流：409/401/400 三种错因必须分开说。
///
/// 混成一句「修改失败」的后果很具体：用户分不清是自己密码打错、名字被占用、
/// 还是格式不对，只会反复重试同一个错误。
String describeChangeUsernameError(Object error) {
  if (error is DioException) {
    final inner = error.error;
    if (inner is ApiException) return _byCode(inner);
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '无法连接服务器，用户名未修改';
    }
    return '改名失败：${describeApiError(error)}';
  }
  if (error is ApiException) return _byCode(error);
  return '改名失败：${describeApiError(error)}';
}

String _byCode(ApiException e) {
  final serverMessage = e.message.trim();
  return switch (e.code) {
    409 =>
      serverMessage.isNotEmpty ? '该用户名已被占用：$serverMessage' : '该用户名已被占用，换一个试试',
    401 => serverMessage.isNotEmpty ? serverMessage : '当前密码不正确',
    400 => serverMessage.isNotEmpty ? '格式不符合要求：$serverMessage' : '用户名格式不符合要求',
    _ => serverMessage.isNotEmpty ? serverMessage : '改名失败，请重试',
  };
}

final accountNotifierProvider =
    StateNotifierProvider<AccountNotifier, AccountState>((ref) {
  return AccountNotifier(
    ref.watch(accountRepositoryProvider),
    ref.watch(authNotifierProvider.notifier),
  );
});
