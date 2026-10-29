import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../data/upgrade_repository.dart';
import '../domain/panel_upgrade.dart';

/// 升级历史列表状态（分页）。
class UpgradeHistoryState {
  const UpgradeHistoryState({
    this.items = const <UpgradeRecord>[],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.loaded = false,
  });

  final List<UpgradeRecord> items;
  final int total;

  /// 首屏加载中（列表为空时显示整页 loading）。
  final bool loading;

  /// 追加一页中（保留已有列表，只在底部显示进度）。
  final bool loadingMore;

  /// 加载错误（有旧数据时不整页替换，只提示）。
  final String? error;

  /// 是否已经成功加载过一次：用来区分「还没加载」与「加载完是空的」。
  final bool loaded;

  bool get hasMore => items.length < total;

  UpgradeHistoryState copyWith({
    List<UpgradeRecord>? items,
    int? total,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    bool? loaded,
  }) {
    return UpgradeHistoryState(
      items: items ?? this.items,
      total: total ?? this.total,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      loaded: loaded ?? this.loaded,
    );
  }
}

/// 升级历史分页编排。
class UpgradeHistoryNotifier extends StateNotifier<UpgradeHistoryState> {
  UpgradeHistoryNotifier(this._repository) : super(const UpgradeHistoryState());

  static const int pageSize = 20;

  final UpgradeRepository _repository;

  Future<void> loadFirst() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await _repository.history(limit: pageSize, offset: 0);
      state = UpgradeHistoryState(
        items: page.items,
        total: page.total,
        loaded: true,
      );
    } on Object catch (e) {
      state = state.copyWith(
        loading: false,
        error: describeApiError(e),
      );
    }
  }

  Future<void> loadMore() async {
    final current = state;
    if (current.loading || current.loadingMore || !current.hasMore) return;
    state = current.copyWith(loadingMore: true, clearError: true);
    try {
      final page = await _repository.history(
        limit: pageSize,
        offset: current.items.length,
      );
      state = state.copyWith(
        items: <UpgradeRecord>[...current.items, ...page.items],
        total: page.total,
        loadingMore: false,
        loaded: true,
      );
    } on Object catch (e) {
      state = state.copyWith(
        loadingMore: false,
        error: describeApiError(e),
      );
    }
  }
}

final upgradeHistoryProvider = StateNotifierProvider.autoDispose<
    UpgradeHistoryNotifier, UpgradeHistoryState>(
  (ref) => UpgradeHistoryNotifier(ref.watch(upgradeRepositoryProvider)),
);
