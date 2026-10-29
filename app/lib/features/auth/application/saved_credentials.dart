import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/secure_store.dart';

/// 连续多少次登录失败后清除本机保存的密码。
///
/// 3 次是「够容忍手滑、又不会一直陪着用户错下去」的折中：第 1 次多半是手滑，
/// 第 2 次可能是换了个输入法，第 3 次仍失败基本可以断定密码已经在别处改过了，
/// 这时候继续留着这份密码，只会让下一次自动填充再把用户送进同一个错误里。
const int maxLoginFailuresBeforeClear = 3;

/// 免密登录（保存密码）的本机凭据状态。
///
/// 为什么必须放在 provider 层而不是登录页的 State：
///  - 登录页随时会被重建（路由重定向、软键盘弹出、系统回收视图），失败计数
///    一旦跟着 State 走就会归零，用户永远等不到「连续 3 次」这个阈值；
///  - 「第 3 次失败」与「清除密码」必须是同一份事实上的同一个动作。若计数在
///    组件里、清除在别处，重建一次就会出现「计到 2 次就清」或「清了但计数还在」。
class SavedCredentialsState {
  const SavedCredentialsState({
    this.loaded = false,
    this.rememberEnabled = false,
    this.savedPassword,
    this.failureCount = 0,
    this.clearedByFailures = false,
  });

  /// 是否已读过一次本机存储。未读过时不要据此渲染「没存过密码」。
  final bool loaded;

  /// 用户是否勾选了「保存密码」（意愿，与是否真的存了密码分开）。
  final bool rememberEnabled;

  /// 已保存的密码原文；null = 本机没有。
  final String? savedPassword;

  /// 连续登录失败次数（登录成功后归零）。
  final int failureCount;

  /// 本次失败是否触发了「清除已保存的密码」，用于在错误文案里如实说明。
  final bool clearedByFailures;

  bool get hasSavedPassword => (savedPassword?.isNotEmpty ?? false);

  SavedCredentialsState copyWith({
    bool? loaded,
    bool? rememberEnabled,
    String? savedPassword,
    bool clearSavedPassword = false,
    int? failureCount,
    bool? clearedByFailures,
  }) {
    return SavedCredentialsState(
      loaded: loaded ?? this.loaded,
      rememberEnabled: rememberEnabled ?? this.rememberEnabled,
      savedPassword:
          clearSavedPassword ? null : (savedPassword ?? this.savedPassword),
      failureCount: failureCount ?? this.failureCount,
      clearedByFailures: clearedByFailures ?? this.clearedByFailures,
    );
  }
}

/// 免密登录凭据编排：读盘、勾选即存/即删、连续失败即清。
///
/// 存储层（[SecureStore]）只负责键值，语义全在这里：
///  1) 默认不勾——只有用户显式勾选过，本机才允许存在密码；
///  2) 取消勾选立刻删——「现在别存了」必须当场生效，不能等下次登录；
///  3) 改服务器地址立刻删——旧密码对新地址毫无意义，留着只会误导自动填充；
///  4) 连续 3 次登录失败立刻删——大概率密码已改，留着等于让用户一直失败。
class SavedCredentialsNotifier extends StateNotifier<SavedCredentialsState> {
  SavedCredentialsNotifier(this._store) : super(const SavedCredentialsState());

  final SecureStore _store;

  /// 读一次本机凭据。
  ///
  /// 已读过就不再读：页面重建时重复读盘会把用户刚勾上的意图读回旧值。
  Future<void> hydrate() async {
    if (state.loaded) return;
    try {
      final enabled = await _store.readRememberEnabled();
      final password = enabled ? await _store.readSavedPassword() : null;
      state = SavedCredentialsState(
        loaded: true,
        rememberEnabled: enabled,
        savedPassword: password,
      );
    } on Object {
      // Keystore 读取失败（换锁屏密码后 key 失效等）时按「没存过」处理。
      // 读盘失败绝不能挡住登录本身——那是把可恢复的小问题放大成登不进去。
      state = const SavedCredentialsState(loaded: true);
    }
  }

  /// 勾选/取消勾选。
  ///
  /// 勾上只记「意愿」，不写任何密码：此刻还没验证过这串密码对不对，
  /// 存下来只会在下次自动填充时把一个错的密码填进去。
  Future<void> setRemember(bool enabled) async {
    if (enabled) {
      await _guard(() => _store.setRememberEnabled(true));
      state = state.copyWith(rememberEnabled: true, clearedByFailures: false);
      return;
    }
    await _guard(_store.clearSavedPassword);
    state = state.copyWith(
      rememberEnabled: false,
      clearSavedPassword: true,
      clearedByFailures: false,
    );
  }

  /// 登录成功：按勾选态落盘或清除。
  Future<void> onLoginSucceeded(String password) async {
    state = state.copyWith(failureCount: 0, clearedByFailures: false);
    if (state.rememberEnabled && password.isNotEmpty) {
      final ok = await _guard(() => _store.savePassword(password));
      if (ok) {
        state = state.copyWith(savedPassword: password);
      } else {
        // 写盘失败就别谎称「已保存」：勾选框保持用户的选择，但状态里没有密码，
        // 下次进页面自然不会自动填充，用户能直观看到「没存上」。
        state = state.copyWith(clearSavedPassword: true);
      }
      return;
    }
    // 未勾选时也清一次：用户可能是这次才取消勾选的，本机不该留旧值。
    await _guard(_store.clearSavedPassword);
    state = state.copyWith(clearSavedPassword: true);
  }

  /// 改密成功后同步本机保存的密码（M11 改密页调用）。
  ///
  /// 不同步的后果很具体：本机存的还是旧密码，下次免密登录必然失败，
  /// 连续 3 次后还会被我们自己的规则清掉——用户会以为「改完密码免密就坏了」。
  Future<void> syncPasswordAfterChange(String password) =>
      onLoginSucceeded(password);

  /// 登录失败：累计次数，到阈值就清除本机密码。
  ///
  /// 返回 true 表示这次失败触发了清除（调用方据此在错误文案里说明）。
  Future<bool> recordFailure() async {
    final next = state.failureCount + 1;
    final shouldClear = next >= maxLoginFailuresBeforeClear &&
        state.hasSavedPassword &&
        !state.clearedByFailures;
    if (!shouldClear) {
      state = state.copyWith(failureCount: next);
      return false;
    }
    await _guard(_store.clearSavedPassword);
    state = state.copyWith(
      failureCount: next,
      clearSavedPassword: true,
      rememberEnabled: false,
      clearedByFailures: true,
    );
    return true;
  }

  /// 通过隐藏入口改了服务器地址：旧密码对新地址没有意义，立刻清掉。
  Future<void> clearForServerChange() async {
    await _guard(_store.clearSavedPassword);
    state = const SavedCredentialsState(loaded: true);
  }

  /// 存储失败（部分机型 Keystore 不可用）不抛出：免密登录是便利功能，
  /// 它失败的正确表现是「这次没记住」，而不是让登录按钮报错。
  Future<bool> _guard(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object {
      return false;
    }
  }
}

final savedCredentialsProvider =
    StateNotifierProvider<SavedCredentialsNotifier, SavedCredentialsState>(
  (ref) => SavedCredentialsNotifier(ref.watch(secureStoreProvider)),
);
