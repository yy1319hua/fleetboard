import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/bootstrap_repository.dart';
import '../domain/bootstrap.dart';

/// 总览状态：聚合 bootstrap 的异步结果 + 前台轮询。
///
/// 轮询策略（M9.2，满足 B2 告警到达，不建 WS）：
///  - 构造即首拉一次；
///  - 每 30s 拉一次（前台；后台被系统节流，回前台由 App 的 onResumed 补拉）；
///  - 下拉刷新触发 [refresh]；
///  - App 生命周期 resumed 亦触发 [refresh]（app.dart 调用）。
class OverviewNotifier extends StateNotifier<AsyncValue<BootstrapResponse>> {
  OverviewNotifier(this._repo) : super(const AsyncValue.loading()) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    load();
  }

  final BootstrapRepository _repo;
  late final Timer _timer;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  Future<void> refresh() async {
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      final data = await _repo.getBootstrap();
      state = AsyncValue.data(data);
    } on Object catch (e, st) {
      // 失败保留上次快照（若有），便于弱网/瞬时错误不白屏。
      if (state is! AsyncData<BootstrapResponse>) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

final overviewProvider =
    StateNotifierProvider<OverviewNotifier, AsyncValue<BootstrapResponse>>(
  (ref) {
    final notifier = OverviewNotifier(ref.watch(bootstrapRepositoryProvider));
    return notifier;
  },
);
