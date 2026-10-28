import 'dart:async';

/// 401 单飞刷新门（M9.2 落地，M9 方案 §2.3）。
///
/// 泛型单飞锁：确保同一时刻只有一个 [task] 在飞，并发调用共享同一 Future/错误。
/// 冷启动预刷新 / onResumed 刷新 / dio401 重放 三触发点共用同一个实例的 [run]，
/// 绝不发生并发刷新（避免重复 refresh 请求与令牌竞争）。
///
/// 刷新所需的 HTTP / 令牌读写由调用方（AuthNotifier）注入 [task]，本类不耦合业务。
class RefreshGate {
  RefreshGate();

  Completer<void>? _completer;

  Future<void> run(Future<void> Function() task) {
    if (_completer != null) return _completer!.future;
    final completer = Completer<void>();
    _completer = completer;
    task()
        .then((_) {
          _completer = null;
          completer.complete();
        })
        .catchError((Object e, StackTrace s) {
          _completer = null;
          completer.completeError(e, s);
        });
    return completer.future;
  }
}
