import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../data/audit_repository.dart';
import '../domain/audit_entry.dart';

/// 审计列表状态。
///
/// `limit` 是**窗口大小**而不是页码：后端只认 limit，没有 offset。
class AuditState {
  const AuditState({
    this.items = const <AuditEntry>[],
    this.limit = AuditRepository.defaultLimit,
    this.loading = true,
    this.loadingMore = false,
    this.error,
    this.loadMoreError,
  });

  final List<AuditEntry> items;
  final int limit;
  final bool loading;
  final bool loadingMore;

  /// 首屏/整体刷新失败。有值且 items 为空时整页展示错误态。
  final String? error;

  /// 「加载更多」这一档失败。已有数据仍然展示，只在底部提示。
  final String? loadMoreError;

  bool get isEmpty => items.isEmpty;

  /// 服务端连这一窗口都填不满 → 已经到底了。
  bool get exhausted => items.length < limit;

  bool get atCap => limit >= AuditRepository.maxLimit;

  /// 只有「窗口被填满」且「没到 500 上限」时才值得继续加载；
  /// 否则按钮点了也是白发一次请求。
  bool get canLoadMore => !loading && !loadingMore && !exhausted && !atCap;

  AuditState copyWith({
    List<AuditEntry>? items,
    int? limit,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    String? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return AuditState(
      items: items ?? this.items,
      limit: limit ?? this.limit,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError:
          clearLoadMoreError ? null : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class AuditNotifier extends StateNotifier<AuditState> {
  AuditNotifier(this._repo) : super(const AuditState()) {
    load();
  }

  final AuditRepository _repo;

  static const int _step = 100;

  /// 首屏 / 重试：整页转圈。
  Future<void> load() async {
    state = AuditState(limit: state.limit);
    await _fetch(state.limit);
  }

  /// 下拉刷新：保留旧数据直到新数据到手，避免「刷新时列表闪空」。
  Future<void> refresh() async {
    try {
      final items = await _repo.list(state.limit);
      state = state.copyWith(
        items: items,
        loading: false,
        clearError: true,
        clearLoadMoreError: true,
      );
    } on Object catch (e) {
      state = state.copyWith(loading: false, error: describeApiError(e));
    }
  }

  /// 加载更多：把窗口加大一档重拉。
  ///
  /// 为什么不是「追加」：没有 offset，重拉回来的就是同一个前缀的前 N 条，
  /// 直接替换既不会重复、也不用做去重；多花的几百行 JSON 在这个体量下可忽略。
  Future<void> loadMore() async {
    if (!state.canLoadMore) return;
    final next = state.limit + _step > AuditRepository.maxLimit
        ? AuditRepository.maxLimit
        : state.limit + _step;
    state = state.copyWith(
      limit: next,
      loading: false,
      loadingMore: true,
      clearLoadMoreError: true,
    );
    try {
      final items = await _repo.list(next);
      state = state.copyWith(
        items: items,
        limit: next,
        loading: false,
        loadingMore: false,
        clearError: true,
      );
    } on Object catch (e) {
      // 回退窗口：这一档没成功，别让 canLoadMore 因为 limit 虚高而永远为 false。
      state = state.copyWith(
        limit: next - _step,
        loading: false,
        loadingMore: false,
        loadMoreError: describeApiError(e),
      );
    }
  }

  Future<void> _fetch(int limit) async {
    try {
      final items = await _repo.list(limit);
      state = AuditState(items: items, limit: limit, loading: false);
    } on Object catch (e) {
      state = AuditState(
        items: const <AuditEntry>[],
        limit: limit,
        loading: false,
        error: describeApiError(e),
      );
    }
  }
}

final auditProvider = StateNotifierProvider<AuditNotifier, AuditState>(
  (ref) => AuditNotifier(ref.watch(auditRepositoryProvider)),
);
