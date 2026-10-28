import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/containers_repository.dart';
import '../domain/container.dart';

/// 容器列表状态：按 serverId 拉取，前台 30s 轮询（对齐 overview 策略）。
class ContainersNotifier extends StateNotifier<AsyncValue<List<Container>>> {
  ContainersNotifier(this._repo, this._serverId)
      : super(const AsyncValue.loading()) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    load();
  }

  final ContainersRepository _repo;
  final int _serverId;
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
      final data = await _repo.list(_serverId);
      state = AsyncValue.data(data);
    } on Object catch (e, st) {
      // 失败保留上次快照（若有），弱网/瞬时错误不白屏。
      if (state is! AsyncData<List<Container>>) {
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

final containersProvider = StateNotifierProvider.family<
    ContainersNotifier, AsyncValue<List<Container>>, int>(
  (ref, serverId) =>
      ContainersNotifier(ref.watch(containersRepositoryProvider), serverId),
);
