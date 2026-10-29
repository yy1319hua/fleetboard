import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/containers_repository.dart';
import '../domain/container_stat.dart';

/// 容器资源占用：按 serverId 拉取，30s 轮询（与容器列表同节奏）。
///
/// **失败必须静默**：stats 只是列表上的一行增强信息。若在这里抛错，
/// 用户会因为「看不到 CPU」而以为整个容器页坏了——而实际上他真正要做的是
/// 去重启某个容器，那个动作完全不依赖 stats。
///
/// **autoDispose**：和 containersProvider 一样，离开详情页就该停轮询，
/// 否则每访问过一台机器就永久留一个后台定时器（还会额外开 SSH 执行 docker stats）。
class ContainerStatsNotifier extends StateNotifier<Map<String, ContainerStat>> {
  ContainerStatsNotifier(this._repo, this._serverId) : super(const {}) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    refresh();
  }

  final ContainersRepository _repo;
  final int _serverId;
  late final Timer _timer;

  /// 返回 key 为 12 位短容器 ID 的映射，便于列表按短 ID 直接命中。
  Future<void> refresh() async {
    try {
      final list = await _repo.stats(_serverId);
      if (!mounted) return;
      state = <String, ContainerStat>{
        for (final s in list)
          if (s.container.isNotEmpty) s.container: s,
      };
    } on Object {
      // 刻意吞掉：见类注释。保留上一次的成功快照（若有），弱网时不至于闪成空。
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

final containerStatsProvider = StateNotifierProvider.autoDispose
    .family<ContainerStatsNotifier, Map<String, ContainerStat>, int>(
  (ref, serverId) =>
      ContainerStatsNotifier(ref.watch(containersRepositoryProvider), serverId),
);

/// 按容器全 ID 找短 ID 对应的占用。
///
/// `docker stats` 只给 12 位短 ID，而 `docker ps` 给 64 位全 ID，两者必须靠前缀匹配。
/// 不做「双向 startsWith」：短 ID 若恰好是另一个容器全 ID 的前缀（12 位重复在
/// 单机上几乎不可能，但理论上存在），双向匹配会串到别人身上；单向更安全。
ContainerStat? statFor(Map<String, ContainerStat> stats, String fullId) {
  if (stats.isEmpty || fullId.length < 12) return null;
  return stats[fullId.substring(0, 12)];
}
