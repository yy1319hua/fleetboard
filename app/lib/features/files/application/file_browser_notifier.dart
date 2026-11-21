import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/files_repository.dart';
import '../domain/file_entry.dart';

/// 文件浏览器状态。
///
/// 路径放在 notifier 里而不是页面 State 里：上传队列、下载任务、编辑器
/// 都需要知道「当前在哪个目录」，且它们可能在页面重建后仍然存活
/// （例如上传进行中用户切到别的 Tab 再回来）。
class FileBrowserState {
  const FileBrowserState({
    required this.path,
    this.home = '',
    this.listing,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.sort = 'name',
    this.order = 'asc',
  });

  final String path;

  /// 登录目录（后端 sftp Getwd）。首次加载后才有值；
  /// 读 `path` 被拒时，界面用它作为「回到我的目录」的落点。
  final String home;
  final FileListing? listing;
  final bool loading;

  /// 正在追加下一页（与 [loading] 分开：整页 loading 会把已有列表换掉，
  /// 而「加载更多」必须保留已看到的条目）。
  final bool loadingMore;
  final Object? error;
  final String sort;
  final String order;

  FileBrowserState copyWith({
    String? path,
    String? home,
    FileListing? listing,
    bool? loading,
    bool? loadingMore,
    Object? error,
    bool clearError = false,
    String? sort,
    String? order,
  }) {
    return FileBrowserState(
      path: path ?? this.path,
      home: home ?? this.home,
      listing: listing ?? this.listing,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      sort: sort ?? this.sort,
      order: order ?? this.order,
    );
  }
}

class FileBrowserNotifier extends StateNotifier<FileBrowserState> {
  FileBrowserNotifier(this._repo, this._serverId)
      : super(const FileBrowserState(path: '', home: '', loading: true)) {
    // 空 path = 由后端决定起始目录（sftp 的登录目录），不再假设根目录可读。
    load('');
  }

  final FilesRepository _repo;
  final int _serverId;

  Future<void> load(String path) async {
    // 切目录时先清空 listing：保留旧目录内容会出现「路径已经是 /etc，
    // 列表还是 /root 的文件」，用户点进去就报错。
    final sameDir = path == state.path;
    state = FileBrowserState(
      path: path,
      home: state.home,
      listing: sameDir ? state.listing : null,
      loading: true,
      sort: state.sort,
      order: state.order,
    );
    try {
      final listing = await _repo.list(
        _serverId,
        path,
        sort: state.sort,
        order: state.order,
      );
      if (!mounted) return;
      // 请求没带 path 时，实际目录由后端决定，这里回填成响应里的 path，
      // 否则面包屑会停在空路径上。
      final resolved = path.isNotEmpty
          ? path
          : (listing.path.isNotEmpty ? listing.path : '/');
      state = state.copyWith(
        path: resolved,
        home: listing.home.isNotEmpty ? listing.home : state.home,
        listing: listing,
        loading: false,
        clearError: true,
      );
    } on Object catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: e);
    }
  }

  Future<void> refresh() => load(state.path);

  /// 追加下一页（后端默认 limit=200，大目录必然要分页）。
  ///
  /// 结果落地前先核对路径：请求在飞的时候用户可能已经进了别的目录，
  /// 把上一页的条目拼到新目录的列表里，会出现「目录里莫名多出几十个文件」。
  Future<void> loadMore() async {
    final current = state.listing;
    if (current == null || state.loadingMore || !current.hasMore) return;
    final pathAtStart = state.path;
    state = state.copyWith(loadingMore: true, clearError: true);
    try {
      final next = await _repo.list(
        _serverId,
        pathAtStart,
        sort: state.sort,
        order: state.order,
        offset: current.entries.length,
        limit: current.limit > 0 ? current.limit : 200,
      );
      if (!mounted || state.path != pathAtStart) return;
      state = state.copyWith(
        listing: current.appended(next),
        loadingMore: false,
      );
    } on Object catch (e) {
      if (!mounted) return;
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  Future<void> setSort(String sort, String order) async {
    state = state.copyWith(sort: sort, order: order);
    await load(state.path);
  }

  /// 进入子目录。
  Future<void> enter(FileEntry dir) => load(dir.path);

  /// 返回上级（根目录时不动）。
  Future<void> up() {
    if (state.path == '/' || state.path.isEmpty) return Future.value();
    final trimmed = state.path.replaceAll(RegExp(r'/+$'), '');
    final idx = trimmed.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : trimmed.substring(0, idx);
    return load(parent);
  }

  /// 删除后原地刷新（不跳转）。
  Future<void> remove(FileEntry entry) async {
    await _repo.remove(_serverId, entry.path);
    await refresh();
  }

  Future<void> rename(FileEntry entry, String newName) async {
    final parent = entry.path.substring(0, entry.path.lastIndexOf('/'));
    final target = parent.isEmpty ? '/$newName' : '$parent/$newName';
    await _repo.rename(_serverId, entry.path, target);
    await refresh();
  }
}

final fileBrowserProvider = StateNotifierProvider.autoDispose
    .family<FileBrowserNotifier, FileBrowserState, int>(
  (ref, serverId) =>
      FileBrowserNotifier(ref.watch(filesRepositoryProvider), serverId),
);
