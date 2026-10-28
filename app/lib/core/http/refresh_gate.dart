import 'dart:async';

/// 401 单飞刷新门（M9.1 骨架，M9.2 接入刷新端点）。
///
/// [ensureFresh] 内部用 [_completer] 复用同一 Completer：
/// 冷启动 / onResumed / dio401 三触发点只调此方法，绝不发生并发刷新
/// （见 M9 方案 §2.3 RefreshGate）。
class RefreshGate {
  RefreshGate(this._doRefresh);

  final Future<void> Function() _doRefresh;

  Completer<void>? _completer;

  Future<void> ensureFresh() {
    if (_completer != null) return _completer!.future;
    final completer = Completer<void>();
    _completer = completer;
    _doRefresh()
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
