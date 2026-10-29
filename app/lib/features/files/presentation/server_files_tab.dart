import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/async_state_view.dart';
import '../application/file_browser_notifier.dart';
import '../application/upload_queue_notifier.dart';
import '../data/files_repository.dart';
import '../domain/file_entry.dart';
import '../domain/file_kind.dart';
import '../domain/file_sizes.dart';
import '../domain/files_error.dart';
import '../domain/remote_path.dart';
import 'download_flow.dart';
import 'file_editor_page.dart';
import 'widgets/file_actions_sheet.dart';
import 'widgets/upload_queue_card.dart';

/// 服务器详情 · 文件段。
///
/// 本文件只负责「浏览 + 把动作路由到对应流程」：
/// 上传状态机在 [UploadQueueNotifier]，下载流程在 [startFileDownload]，
/// 在线编辑在 [FileEditorPage]。文件操作的状态复杂度远高于 UI，
/// 混在一个文件里会很快失控。
class ServerFilesTab extends ConsumerStatefulWidget {
  const ServerFilesTab({super.key, required this.serverId});

  final int serverId;

  @override
  ConsumerState<ServerFilesTab> createState() => _ServerFilesTabState();
}

class _ServerFilesTabState extends ConsumerState<ServerFilesTab> {
  /// 上次看到的「队列完成计数」。
  ///
  /// 用它而不是监听某个任务：用户可能在上传期间离开了这个页面，Widget 重建后
  /// 早已错过「任务完成」那个事件，但目录内容确实变了，必须补一次刷新。
  int? _lastDoneCount;

  int get _serverId => widget.serverId;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileBrowserProvider(_serverId));
    final queue = ref.watch(uploadQueueProvider);
    _syncDirectoryAfterUpload(queue.doneCount);

    return Column(
      children: <Widget>[
        _PathBar(
          path: state.path,
          onUp: () => ref.read(fileBrowserProvider(_serverId).notifier).up(),
          onRefresh: () =>
              ref.read(fileBrowserProvider(_serverId).notifier).refresh(),
          onSort: () => _pickSort(state),
          onUpload: () => _pickAndUpload(state),
        ),
        if (state.error != null && state.listing != null)
          InlineErrorBar(
            message: describeFilesError(state.error!, path: state.path),
            onRetry: () =>
                ref.read(fileBrowserProvider(_serverId).notifier).refresh(),
          ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _buildBody(state)),
              // 悬浮在列表之上：上传进行中用户还要继续浏览/操作文件。
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: UploadQueueCard(serverId: _serverId),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _syncDirectoryAfterUpload(int doneCount) {
    final last = _lastDoneCount;
    _lastDoneCount = doneCount;
    if (last == null || doneCount == last) return;
    // 不能在 build 期间改状态：交给下一帧，刷新当前目录（保留路径，不跳回根）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(fileBrowserProvider(_serverId).notifier).refresh();
    });
  }

  Widget _buildBody(FileBrowserState state) {
    if (state.loading && state.listing == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              '正在读取 ${state.path}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    if (state.error != null && state.listing == null) {
      return _ErrorPane(
        path: state.path,
        error: state.error!,
        onRetry: () => ref.read(fileBrowserProvider(_serverId).notifier).refresh(),
        onUp: state.path == '/'
            ? null
            : () => ref.read(fileBrowserProvider(_serverId).notifier).up(),
      );
    }
    final listing = state.listing;
    if (listing == null) {
      return const SizedBox.shrink();
    }
    if (listing.entries.isEmpty) {
      return _EmptyPane(
        path: state.path,
        onUpload: () => _pickAndUpload(state),
        onRefresh: () =>
            ref.read(fileBrowserProvider(_serverId).notifier).refresh(),
      );
    }
    return _FileList(
      listing: listing,
      loadingMore: state.loadingMore,
      onTapEntry: _onEntryTap,
      onMore: () => ref.read(fileBrowserProvider(_serverId).notifier).loadMore(),
      onRefresh: () =>
          ref.read(fileBrowserProvider(_serverId).notifier).refresh(),
    );
  }

  // ── 文件/目录动作 ─────────────────────────────────────────────────

  Future<void> _onEntryTap(FileEntry entry) async {
    if (entry.dir) {
      await ref.read(fileBrowserProvider(_serverId).notifier).enter(entry);
      return;
    }
    await _showActions(entry);
  }

  Future<void> _showActions(FileEntry entry) async {
    final action = await showFileActions(context, entry);
    if (!mounted || action == null) return;
    switch (action) {
      case FileAction.download:
        await startFileDownload(
          context,
          ref,
          serverId: _serverId,
          remotePath: entry.path,
          name: entry.name,
          totalBytes: entry.size,
        );
        if (!mounted) return;
        // 下载不改远端内容，但顺手对齐一次真实状态：用户刚才是基于列表里的
        // 旧大小点的下载，文件可能已经被别人改过。
        await ref.read(fileBrowserProvider(_serverId).notifier).refresh();
      case FileAction.edit:
        // 入口本身已按大小/类型收窄，这里再挡一次：真正决定能不能编辑的是
        // 后端 1MiB 上限，前端任何一处漏判都会变成一次白跑的往返。
        if (entry.size > maxEditableBytes) {
          _toast('${entry.name} 超过 1MiB，无法在线编辑');
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FileEditorPage(serverId: _serverId, entry: entry),
          ),
        );
        if (!mounted) return;
        await ref.read(fileBrowserProvider(_serverId).notifier).refresh();
      case FileAction.properties:
        await _showProperties(entry);
      case FileAction.rename:
        await _rename(entry);
      case FileAction.copy:
        await _copy(entry);
      case FileAction.remove:
        await _remove(entry);
    }
  }

  Future<void> _showProperties(FileEntry entry) async {
    int? size;
    Object? failure;
    try {
      size = await ref.read(filesRepositoryProvider).statSize(_serverId, entry.path);
    } on Object catch (e) {
      failure = e;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('属性'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('路径：${entry.path}'),
            const SizedBox(height: 4),
            if (failure != null)
              Text(
                describeFilesError(failure, path: entry.path),
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              )
            else
              Text('大小：${formatBytes(size ?? entry.size)}（${size ?? entry.size} 字节）'),
            Text('权限：${entry.mode}'),
            Text('属主：uid ${entry.uid} / gid ${entry.gid}'),
            Text('修改时间：${_fmt(entry.modTime)}'),
            if (entry.dir) const Text('类型：目录'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(FileEntry entry) async {
    final name = await _askName(entry.name, '新名称');
    if (!mounted || name == null || name.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fileBrowserProvider(_serverId).notifier).rename(entry, name);
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('重命名失败：${describeFilesError(e, path: entry.path)}')),
      );
    }
  }

  Future<void> _copy(FileEntry entry) async {
    final name = await _askName('${entry.name}.copy', '复制为');
    if (!mounted || name == null || name.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(filesRepositoryProvider).copy(
            _serverId,
            entry.path,
            joinRemotePath(parentOf(entry.path), name),
          );
      await ref.read(fileBrowserProvider(_serverId).notifier).refresh();
      messenger.showSnackBar(SnackBar(content: Text('已复制为 $name')));
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('复制失败：${describeFilesError(e, path: entry.path)}')),
      );
    }
  }

  Future<void> _remove(FileEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${entry.name}？'),
        content: Text(entry.dir
            ? '这是目录，删除会连同其中所有内容一起递归删除，且不可撤销。'
            : '删除后不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fileBrowserProvider(_serverId).notifier).remove(entry);
      messenger.showSnackBar(SnackBar(content: Text('已删除 ${entry.name}')));
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('删除失败：${describeFilesError(e, path: entry.path)}')),
      );
    }
  }

  // ── 上传 ─────────────────────────────────────────────────────────

  Future<void> _pickAndUpload(FileBrowserState state) async {
    final source = await showModalBottomSheet<_UploadSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(
                '上传到 ${state.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('从文档选择'),
              subtitle: const Text('任意类型，可多选'),
              onTap: () => Navigator.of(ctx).pop(_UploadSource.documents),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('图片，可多选'),
              onTap: () => Navigator.of(ctx).pop(_UploadSource.photos),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;

    final picked = await _pickFiles(source);
    if (!mounted || picked.isEmpty) return;

    // 用当前目录已有的名字做撞名判断。分页只加载了第一页时，第二页之后的重名
    // 检测不到——这是已知的近似：服务端没有「按名字查询」的端点。
    final taken = <String>{
      for (final e in state.listing?.entries ?? const <FileEntry>[]) e.name,
    };
    final rejected = <String>[];
    for (final file in picked) {
      if (!mounted) return;
      final name = await _resolveUploadName(file.name, state.path, taken);
      if (name == null) continue;
      taken.add(name);
      final error = ref.read(uploadQueueProvider.notifier).enqueue(
            serverId: _serverId,
            remotePath: joinRemotePath(state.path, name),
            localPath: file.path,
            totalBytes: file.size,
          );
      if (error != null) rejected.add(error);
    }
    if (rejected.isNotEmpty && mounted) _toast(rejected.first);
  }

  Future<List<_Picked>> _pickFiles(_UploadSource source) async {
    try {
      if (source == _UploadSource.documents) {
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: true,
          withData: false,
          withReadStream: false,
        );
        final out = <_Picked>[];
        for (final file in result?.files ?? const <PlatformFile>[]) {
          final path = file.path;
          if (path == null || path.isEmpty) continue;
          out.add(_Picked(name: file.name, path: path, size: file.size));
        }
        return out;
      }

      final images = await ImagePicker().pickMultiImage();
      final now = DateTime.now();
      final out = <_Picked>[];
      for (var i = 0; i < images.length; i++) {
        final image = images[i];
        final length = await File(image.path).length();
        out.add(
          _Picked(
            name: _photoName(image.name, image.path, i, now),
            path: image.path,
            size: length,
          ),
        );
      }
      return out;
    } on Object catch (e) {
      if (!mounted) return const <_Picked>[];
      _toast(_pickerFailure(e));
      return const <_Picked>[];
    }
  }

  /// 相册图片的原始名常常是 `image_picker_1699...jpg` 这种缓存名，
  /// 直接上传会让服务端出现一堆无法辨认的文件，所以换成时间戳命名。
  static String _photoName(String name, String path, int index, DateTime now) {
    final lower = name.toLowerCase();
    final usable = name.isNotEmpty &&
        !lower.startsWith('image_picker') &&
        !lower.startsWith('scaled_');
    if (usable) return name;
    final dot = path.lastIndexOf('.');
    final ext = dot > 0 ? path.substring(dot) : '.jpg';
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'photo_${stamp}_$index$ext';
  }

  /// 撞名三选。返回 null 表示用户跳过了这个文件。
  Future<String?> _resolveUploadName(
    String name,
    String dir,
    Set<String> taken,
  ) async {
    if (!taken.contains(name)) return name;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('同名文件已存在'),
        content: Text('$dir 下已有 $name。\n覆盖会直接用新文件替换它，原内容不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('跳过'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: const Text('保留两者'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('overwrite'),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (!mounted) return null;
    if (choice == 'overwrite') return name;
    if (choice == 'keep') return freeName(name, taken);
    return null;
  }

  static String _pickerFailure(Object error) {
    if (error is PlatformException) {
      final detail = error.message?.trim();
      return '无法打开系统选择器'
          '${detail == null || detail.isEmpty ? '' : '（$detail）'}';
    }
    return '选择文件失败：${describeApiError(error)}';
  }

  // ── 通用小工具 ───────────────────────────────────────────────────

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askName(String initial, String title) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(helperText: '只需名称，不用写路径'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSort(FileBrowserState state) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final opt in const <(String, String, String)>[
              ('name', 'asc', '名称 ↑'),
              ('name', 'desc', '名称 ↓'),
              ('size', 'desc', '大小（大到小）'),
              ('size', 'asc', '大小（小到大）'),
              ('mod_time', 'desc', '修改时间（新到旧）'),
              ('mod_time', 'asc', '修改时间（旧到新）'),
            ])
              ListTile(
                title: Text(opt.$3),
                trailing: state.sort == opt.$1 && state.order == opt.$2
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.of(ctx).pop('${opt.$1}:${opt.$2}'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final parts = choice.split(':');
    await ref
        .read(fileBrowserProvider(_serverId).notifier)
        .setSort(parts[0], parts[1]);
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

enum _UploadSource { documents, photos }

class _Picked {
  const _Picked({required this.name, required this.path, required this.size});

  final String name;
  final String path;
  final int size;
}

/// 目录读取失败（无缓存可显示时）：文案 + 可执行动作，而不是一行异常 toString。
class _ErrorPane extends StatelessWidget {
  const _ErrorPane({
    required this.path,
    required this.error,
    required this.onRetry,
    this.onUp,
  });

  final String path;
  final Object error;
  final VoidCallback onRetry;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.folder_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              describeFilesError(error, path: path),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
            if (onUp != null) ...<Widget>[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onUp,
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: Text('返回 ${parentOf(path)}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane({
    required this.path,
    required this.onUpload,
    required this.onRefresh,
  });

  final String path;
  final VoidCallback onUpload;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.inbox_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              emptyDirHint(path),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onUpload,
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('上传文件'),
            ),
            TextButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.path,
    required this.onUp,
    required this.onRefresh,
    required this.onSort,
    required this.onUpload,
  });

  final String path;
  final VoidCallback onUp;
  final VoidCallback onRefresh;
  final VoidCallback onSort;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final atRoot = path == '/' || path.isEmpty;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        // 路径可能很长：横向可滚，避免把右侧按钮挤出去。
        child: Row(
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: '上一级',
              onPressed: atRoot ? null : onUp,
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    atRoot ? '/' : path,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: '上传到当前目录',
              onPressed: onUpload,
            ),
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: '排序',
              onPressed: onSort,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: onRefresh,
            ),
          ],
        ),
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.listing,
    required this.loadingMore,
    required this.onTapEntry,
    required this.onMore,
    required this.onRefresh,
  });

  final FileListing listing;
  final bool loadingMore;
  final Future<void> Function(FileEntry entry) onTapEntry;
  final VoidCallback onMore;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final showMore = listing.hasMore;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        // 给底部的上传队列卡片留出空间，否则最后一条永远被压住。
        padding: const EdgeInsets.only(bottom: 104),
        itemCount: listing.entries.length + (showMore ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i >= listing.entries.length) {
            return _LoadMoreTile(
              loading: loadingMore,
              loaded: listing.entries.length,
              total: listing.total,
              onMore: onMore,
            );
          }
          final entry = listing.entries[i];
          return ListTile(
            dense: true,
            leading: Icon(
              entry.dir ? Icons.folder_outlined : _iconFor(entry.name),
              color: entry.dir
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
            title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${entry.mode}  ${_fmt(entry.modTime)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            trailing: Text(
              entry.sizeLabel,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            onTap: () => onTapEntry(entry),
            onLongPress: () => onTapEntry(entry),
          );
        },
      ),
    );
  }

  static IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.yml') || lower.endsWith('.yaml')) {
      return Icons.account_tree_outlined;
    }
    if (lower.endsWith('.log')) return Icons.receipt_long_outlined;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.xz')) {
      return Icons.folder_zip_outlined;
    }
    if (looksLikeTextFile(name)) return Icons.tune_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _LoadMoreTile extends StatelessWidget {
  const _LoadMoreTile({
    required this.loading,
    required this.loaded,
    required this.total,
    required this.onMore,
  });

  final bool loading;
  final int loaded;
  final int total;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: OutlinedButton.icon(
        onPressed: onMore,
        icon: const Icon(Icons.expand_more, size: 18),
        label: Text('加载更多（已显示 $loaded / $total）'),
      ),
    );
  }
}
