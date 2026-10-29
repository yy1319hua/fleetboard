import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/code_editor.dart';
import '../data/files_repository.dart';
import '../domain/file_entry.dart';
import '../domain/file_kind.dart';
import '../domain/file_sizes.dart';
import '../domain/files_error.dart';
import '../domain/remote_path.dart';

/// 在线编辑页（仅文本、仅 ≤1MiB）。
///
/// 冲突处理是这个页面存在的核心理由：后端写入是原子的（临时文件 → 保留权限属主
/// → rename），但它**不会**检查「你编辑期间别人是否也改了」——最后一次 rename
/// 无条件覆盖。所以保存前必须自己比对文件大小，把三选交给用户，
/// 否则就是「两个人同时改 nginx.conf，谁后点保存谁的内容生效，另一个人的改动
/// 静默消失」。
class FileEditorPage extends ConsumerStatefulWidget {
  const FileEditorPage({
    super.key,
    required this.serverId,
    required this.entry,
  });

  final int serverId;
  final FileEntry entry;

  @override
  ConsumerState<FileEditorPage> createState() => _FileEditorPageState();
}

class _FileEditorPageState extends ConsumerState<FileEditorPage> {
  final TextEditingController _controller = TextEditingController();

  AsyncValue<RemoteText> _remote = const AsyncValue<RemoteText>.loading();

  /// 当前编辑的远端路径与文件名（「另存为副本」后会切换）。
  late String _path = widget.entry.path;
  late String _name = widget.entry.name;

  /// 上次成功持久化的内容：与编辑框不同即「有未保存改动」。
  String _saved = '';

  /// 编辑开始（或上次保存成功）时服务端的字节数——冲突检测的基线。
  int _baselineSize = 0;

  bool _saving = false;

  bool get _dirty => _controller.text != _saved;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _remote = const AsyncValue<RemoteText>.loading());
    try {
      final remote = await ref
          .read(filesRepositoryProvider)
          .readTextWithSize(widget.serverId, _path);
      if (!mounted) return;
      _controller.text = remote.content;
      setState(() {
        _saved = remote.content;
        _baselineSize = remote.size;
        _remote = AsyncValue<RemoteText>.data(remote);
      });
    } on Object catch (e, stack) {
      if (!mounted) return;
      setState(() => _remote = AsyncValue<RemoteText>.error(e, stack));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dirty = _dirty;

    return PopScope(
      canPop: !dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _saving) return;
        final leave = await _confirm(
          title: '放弃修改？',
          message: '「$_name」有未保存的改动，返回将丢失这些改动。',
          confirmLabel: '放弃修改',
        );
        if (!context.mounted || leave != true) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  _saving
                      ? '保存中…'
                      : (dirty ? '未保存' : '已保存'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: dirty
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              tooltip: '保存',
              onPressed: (_saving || !dirty) ? null : _save,
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: AsyncStateView<RemoteText>(
                value: _remote,
                emptyHint: '这个文件是空的。', // 不会命中：空文件也必须能编辑
                isEmpty: (_) => false,
                onRetry: _load,
                loadingHint: '正在读取 ${formatBytes(widget.entry.size)} 文本…',
                padding: const EdgeInsets.all(12),
                builder: (_) => Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: CodeEditor(
                    controller: _controller,
                    hintText: '这个文件是空的，直接输入即可',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
            _Footer(
              path: _path,
              size: formatBytes(utf8.encode(_controller.text).length),
              dirty: dirty,
            ),
          ],
        ),
      ),
    );
  }

  // ── 保存 ─────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller.text;
    final byteLength = utf8.encode(text).length;
    if (byteLength > maxEditableBytes) {
      _toast('内容 ${formatBytes(byteLength)}，超过 1MiB 上限，请删减后再保存');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(filesRepositoryProvider);

      // 保存前重新取一次大小：不能信列表页的旧数据，那是几分钟前的世界。
      int? remoteSize;
      Object? statError;
      try {
        remoteSize = await repo.statSize(widget.serverId, _path);
      } on Object catch (e) {
        statError = e;
      }
      if (!mounted) return;

      if (statError != null) {
        final go = await _confirm(
          title: '无法确认远端状态',
          message: '${describeFilesError(statError, path: _path)}\n\n'
              '现在写入可能覆盖别人的改动。仍要写入吗？',
          confirmLabel: '仍然写入',
        );
        if (!mounted || go != true) return;
      } else if (remoteSize != null && remoteSize != _baselineSize) {
        final choice = await _askConflict(remoteSize);
        if (!mounted || choice == null) return;
        switch (choice) {
          case _ConflictChoice.discard:
            await _reloadFromRemote();
            return;
          case _ConflictChoice.saveAsCopy:
            final copyName = await _askCopyName();
            if (!mounted || copyName == null || copyName.isEmpty) return;
            final target = joinRemotePath(parentOf(_path), copyName);
            await _writeTo(target, text, switchTarget: true);
            return;
          case _ConflictChoice.overwrite:
            break; // 继续往下走，覆盖远端
        }
      }

      await _writeTo(_path, text);
    } on Object catch (e) {
      if (!mounted) return;
      _toast('保存失败：${describeFilesError(e, path: _path)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _writeTo(
    String path,
    String text, {
    bool switchTarget = false,
  }) async {
    await ref.read(filesRepositoryProvider).writeText(widget.serverId, path, text);
    if (!mounted) return;
    setState(() {
      if (switchTarget) {
        _path = path;
        _name = baseNameOf(path);
      }
      _saved = text;
      _baselineSize = utf8.encode(text).length;
    });
    _toast(switchTarget ? '已另存为 ${baseNameOf(path)}' : '已保存');
  }

  /// 放弃我的修改 = 用远端当前内容替换编辑器内容（并刷新基线）。
  ///
  /// 不是简单关闭页面：用户需要看见「别人的版本长什么样」才能决定接下来怎么办。
  Future<void> _reloadFromRemote() async {
    setState(() => _remote = const AsyncValue<RemoteText>.loading());
    try {
      final remote = await ref
          .read(filesRepositoryProvider)
          .readTextWithSize(widget.serverId, _path);
      if (!mounted) return;
      _controller.text = remote.content;
      setState(() {
        _saved = remote.content;
        _baselineSize = remote.size;
        _remote = AsyncValue<RemoteText>.data(remote);
      });
      _toast('已载入服务端最新内容，我的修改已放弃');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _remote = AsyncValue<RemoteText>.error(e, StackTrace.current));
      _toast('载入远端内容失败：${describeFilesError(e, path: _path)}');
    }
  }

  Future<_ConflictChoice?> _askConflict(int remoteSize) {
    return showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文件已被他人修改'),
        content: Text(
          '保存前你在编辑的这个文件是 ${formatBytes(_baselineSize)}，'
          '现在是 ${formatBytes(remoteSize)}。\n\n'
          '你保存会覆盖别人刚写进去的内容。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_ConflictChoice.saveAsCopy),
            child: const Text('另存为副本'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_ConflictChoice.discard),
            child: const Text('放弃我的修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_ConflictChoice.overwrite),
            child: const Text('覆盖远端'),
          ),
        ],
      ),
    );
  }

  Future<String?> _askCopyName() {
    final controller = TextEditingController(
      text: freeName(_name, <String>{_name}),
    );
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('另存为副本'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            helperText: '保存在 ${parentOf(_path)} 下',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}

enum _ConflictChoice { overwrite, discard, saveAsCopy }

class _Footer extends StatelessWidget {
  const _Footer({
    required this.path,
    required this.size,
    required this.dirty,
  });

  final String path;
  final String size;
  final bool dirty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$size${dirty ? ' · 有未保存改动' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: dirty
                      ? theme.colorScheme.tertiary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
