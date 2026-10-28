import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../overview/application/overview_notifier.dart';
import '../data/alerts_repository.dart';
import '../domain/alert_event.dart';

/// 通知中心状态：列表加载 + 标记已读（乐观更新 + 刷新总览角标，B7）。
class AlertsNotifier extends StateNotifier<AsyncValue<List<AlertEvent>>> {
  AlertsNotifier(this._repo, this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final AlertsRepository _repo;
  final Ref _ref;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  Future<void> refresh() async {
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      final list = await _repo.list();
      state = AsyncValue.data(list);
    } on Object catch (e, st) {
      if (state is! AsyncData<List<AlertEvent>>) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// 标记已读：乐观翻转为已读，成功后刷新总览未读角标；失败回滚。
  Future<void> markRead(int id) async {
    final current = state.value;
    if (current == null) return;
    final idx = current.indexWhere((a) => a.id == id);
    if (idx < 0 || current[idx].isRead) return;

    final updated = <AlertEvent>[...current];
    updated[idx] = updated[idx].copyWith(isRead: true);
    state = AsyncValue.data(updated);
    try {
      await _repo.markRead(id);
      // Web 与 App 同源已读，刷新总览未读角标（B7）。
      _ref.read(overviewProvider.notifier).refresh();
    } on Object {
      state = AsyncValue.data(current);
    }
  }
}

final alertsProvider =
    StateNotifierProvider<AlertsNotifier, AsyncValue<List<AlertEvent>>>(
  (ref) => AlertsNotifier(ref.watch(alertsRepositoryProvider), ref),
);
