import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/containers_repository.dart';
import '../domain/container.dart';

/// 容器列表状态：按 serverId 拉取，前台 30s 轮询（对齐 overview 策略）。
///
/// **必须 autoDispose**：不释放的话，用户每进过一次某台服务器的详情页，
/// 就永久留下一个 30s 轮询（StateNotifier 被 provider 容器持有，没人会再 dispose 它），
/// 访问十台机器就是十个定时器在后台打 SSH。服务器越多越耗电，且是线性叠加。
class ContainersNotifier extends StateNotifier<AsyncValue<List<Container>>> {
  ContainersNotifier(this._repo, this._serverId)
      : super(const AsyncValue.loading()) {
    _startTimer();
    load();
  }

  final ContainersRepository _repo;
  final int _serverId;

  /// 可为 null：所在分段不可见时停掉轮询（见 [setActive]）。
  Timer? _timer;

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
  }

  /// 分段可见性变化：不可见时停轮询，重新可见时先补拉一次再恢复节奏。
  ///
  /// 之所以不在切走时直接销毁 provider：详情页用 KeepAlive 保留了子树，
  /// 销毁会连带丢掉列表数据与滚动位置，用户切回来看到从头加载的空白。
  /// 保留数据、只停远端请求，才是这两件事的正确切分。
  void setActive(bool active) {
    if (active) {
      if (_timer != null) return; // 已经活跃，避免每次 didChangeDependencies 都补拉
      _startTimer();
      refresh();
      return;
    }
    _timer?.cancel();
    _timer = null;
  }

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
    _timer?.cancel();
    super.dispose();
  }
}

/// 容器列表 provider（autoDispose）。
///
/// 详情页内用 KeepAlive 保证 Tab 来回切换不重拉；一旦离开详情页，
/// 所有监听者消失，autoDispose 触发 [ContainersNotifier.dispose] 停掉轮询。
/// 这两者不矛盾：KeepAlive 管「页面内」，autoDispose 管「页面外」。
final containersProvider = StateNotifierProvider.autoDispose
    .family<ContainersNotifier, AsyncValue<List<Container>>, int>(
  (ref, serverId) =>
      ContainersNotifier(ref.watch(containersRepositoryProvider), serverId),
);
