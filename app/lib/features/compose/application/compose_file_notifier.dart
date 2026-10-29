import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../data/compose_repository.dart';
import '../domain/compose_document.dart';
import '../domain/compose_models.dart';

/// 目录浏览的缓存键。
///
/// 用 record（结构相等）而不是自定义类：Riverpod family 靠 `==` 命中缓存，
/// 自定义类忘记写 `==`/`hashCode` 会让每次 build 都新开一次 SSH 会话。
typedef ComposeDirKey = ({int serverId, String? dir});

/// 单目录浏览结果。
///
/// autoDispose：离开 Compose 页就释放。浏览本身是「点一层查一层」，
/// 缓存旧目录没有价值，反而会让用户看到下钻前的旧列表。
final composeListingProvider =
    FutureProvider.autoDispose.family<ComposeListing, ComposeDirKey>(
  (ref, key) =>
      ref.watch(composeRepositoryProvider).list(key.serverId, dir: key.dir),
);

/// 单文件编辑会话的键。
typedef ComposeFileKey = ({int serverId, String path});

/// 文件编辑会话状态。
///
/// 为什么不用 `AsyncValue`：这里有两份需要同时存在的文本——**服务端原文**
/// 与**编辑中的草稿**——外加一个必须跨 build 存活的「外部替换版本号」。
/// 用 AsyncValue 包起来只会让 `dirty` 判断散落在 UI 里。
class ComposeFileState {
  const ComposeFileState({
    required this.path,
    this.loading = true,
    this.loadError,
    this.original = '',
    this.draft = '',
    this.revision = 0,
    this.saving = false,
    this.busyAction,
  });

  final String path;
  final bool loading;
  final String? loadError;

  /// 服务端当前原文。保存成功后与 [draft] 一起推进。
  final String original;

  /// 编辑中的全文。所有改动（表单/原文/剪贴板）都只作用于它。
  final String draft;

  /// 外部整份替换（加载、放弃改动、保存成功）时 +1。
  ///
  /// 输入框类控件只在版本号变化时重置文本：否则用户每敲一个字，
  /// 上层重建就把 controller 覆盖回去，光标会跳到开头。
  final int revision;

  final bool saving;

  /// 正在执行的 compose 动作（up/down/restart/ps），null 表示空闲。
  final String? busyAction;

  bool get dirty => draft != original;

  bool get busy => saving || busyAction != null;

  /// 草稿的解析结果。
  ///
  /// 每次访问都重新解析：compose 文件通常只有几 KB，`package:yaml` 解析在
  /// 毫秒级，而缓存它需要额外维护「草稿 → 解析结果」的一致性，得不偿失。
  ComposeParseResult get parsed => parseComposeServices(draft);

  ComposeFileState copyWith({
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    String? original,
    String? draft,
    int? revision,
    bool? saving,
    String? busyAction,
    bool clearBusyAction = false,
  }) {
    return ComposeFileState(
      path: path,
      loading: loading ?? this.loading,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      original: original ?? this.original,
      draft: draft ?? this.draft,
      revision: revision ?? this.revision,
      saving: saving ?? this.saving,
      busyAction: clearBusyAction ? null : (busyAction ?? this.busyAction),
    );
  }
}

/// 一次 compose 文件编辑会话。
class ComposeFileNotifier extends StateNotifier<ComposeFileState> {
  ComposeFileNotifier(this._repo, this._serverId, String path)
      : super(ComposeFileState(path: path)) {
    load();
  }

  final ComposeRepository _repo;
  final int _serverId;

  Future<void> load() async {
    state = state.copyWith(loading: true, clearLoadError: true);
    try {
      final content = await _repo.read(_serverId, state.path);
      state = state.copyWith(
        loading: false,
        original: content.content,
        draft: content.content,
        // 首屏与重试都要重建输入框。
        revision: state.revision + 1,
        clearLoadError: true,
      );
    } on Object catch (e) {
      state = state.copyWith(loading: false, loadError: describeApiError(e));
    }
  }

  /// 原文编辑：草稿直接变成用户敲的文本，不做任何解析或规整。
  void editSource(String text) {
    state = state.copyWith(draft: text);
  }

  /// 表单改动：用 `YamlEditor` 就地把字段打进草稿，返回是否真的产生了变化。
  ///
  /// 抛 [ComposeEditException] 时草稿保持原样，由页面提示「请用原文编辑」。
  bool applyEdit(ServiceEdit edit) {
    if (edit.isEmpty) return false;
    final next = applyComposeEdits(state.draft, [edit]);
    if (next == state.draft) return false;
    state = state.copyWith(draft: next);
    return true;
  }

  /// 剪贴板整份替换：只改草稿，是否写回服务器由用户再确认一次（保存）。
  void replaceAll(String text) {
    state = state.copyWith(draft: text, revision: state.revision + 1);
  }

  /// 放弃改动，回到服务端原文。
  void discard() {
    state = state.copyWith(
      draft: state.original,
      revision: state.revision + 1,
      clearLoadError: true,
    );
  }

  /// 写回服务器。成功后原文推进到草稿，`dirty` 归零。
  Future<int> save() async {
    if (!state.dirty) return 0;
    state = state.copyWith(saving: true);
    try {
      final size = await _repo.write(_serverId, state.path, state.draft);
      state = state.copyWith(
        saving: false,
        original: state.draft,
        revision: state.revision + 1,
      );
      return size;
    } on Object {
      state = state.copyWith(saving: false);
      rethrow;
    }
  }

  /// 执行 compose 动作。返回合并输出，异常由页面提示（输出同时保留在异常里）。
  Future<ComposeActionResult> runAction(String action) async {
    if (state.busy) {
      throw const ComposeEditException('上一个动作还没结束，请等它完成');
    }
    state = state.copyWith(busyAction: action);
    try {
      final result = await _repo.runAction(_serverId, state.path, action);
      state = state.copyWith(clearBusyAction: true);
      return result;
    } on Object {
      state = state.copyWith(clearBusyAction: true);
      rethrow;
    }
  }
}

final composeFileProvider = StateNotifierProvider.autoDispose
    .family<ComposeFileNotifier, ComposeFileState, ComposeFileKey>(
  (ref, key) => ComposeFileNotifier(
    ref.watch(composeRepositoryProvider),
    key.serverId,
    key.path,
  ),
);
