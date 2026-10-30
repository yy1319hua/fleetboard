import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/bootstrap_cache.dart';
import '../data/bootstrap_repository.dart';
import '../domain/bootstrap.dart';

/// 总览状态：聚合 bootstrap 的异步结果 + 前台轮询 + 缓存优先。
///
/// 轮询策略（M9.2，满足 B2 告警到达，不建 WS）：
///  - 构造即首拉一次；
///  - 每 30s 拉一次（前台；后台被系统节流，回前台由 App 的 onResumed 补拉）；
///  - 下拉刷新触发 [refresh]；
///  - App 生命周期 resumed 亦触发 [refresh]（app.dart 调用）。
///
/// 缓存优先（v0.4.3）：构造时并行读本地快照，先渲染旧数据（顶部标注时间），
/// 网络结果回来后覆盖并把缓存标记清掉。弱网/离线时用户看到的是「上次的数据」，
/// 而不是一片空白。
class OverviewNotifier extends StateNotifier<AsyncValue<BootstrapResponse>> {
  OverviewNotifier(
    this._repo,
    this._cache,
    this._onCacheAt,
  ) : super(const AsyncValue.loading()) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    _restoreFromCache();
    load();
  }

  final BootstrapRepository _repo;
  final BootstrapCache _cache;

  /// 回调：展示缓存时给出缓存时间，换成网络数据时给 null。
  final void Function(DateTime? at) _onCacheAt;

  late final Timer _timer;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  Future<void> refresh() async {
    await _fetch();
  }

  /// 先出缓存，再等网络。失败静默（缓存本来就可能不存在）。
  Future<void> _restoreFromCache() async {
    final cached = await _cache.load();
    if (cached == null || state is AsyncData<BootstrapResponse>) return;
    _onCacheAt(cached.at);
    state = AsyncValue.data(cached.data);
  }

  Future<void> _fetch() async {
    try {
      final data = await _repo.getBootstrap();
      state = AsyncValue.data(data);
      _onCacheAt(null);
      unawaited(_cache.save(data, DateTime.now()));
    } on Object catch (e, st) {
      // 失败保留上次快照（缓存或上一次成功的数据），便于弱网/瞬时错误不白屏。
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
    final notifier = OverviewNotifier(
      ref.watch(bootstrapRepositoryProvider),
      ref.watch(bootstrapCacheProvider),
      (at) => ref.read(overviewCacheAtProvider.notifier).state = at,
    );
    return notifier;
  },
);
