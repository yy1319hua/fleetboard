import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/hold_to_confirm.dart';
import '../data/resources_repository.dart';
import '../domain/docker_resource.dart';

/// 删除数据卷确认层（长按触发）。成功返回 true。
///
/// 卷里装的是**数据**，删掉不可恢复，因此和删镜像一样用 [HoldToConfirm]：
/// 误触时手指抬不起来，比「弹窗点确定」更能拦住手滑。
Future<bool> showDeleteVolumeSheet(
  BuildContext context, {
  required int serverId,
  required DockerVolume volume,
}) async {
  final deleted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _DeleteVolumeSheet(
      serverId: serverId,
      volume: volume,
    ),
  );
  return deleted ?? false;
}

class _DeleteVolumeSheet extends ConsumerStatefulWidget {
  const _DeleteVolumeSheet({required this.serverId, required this.volume});

  final int serverId;
  final DockerVolume volume;

  @override
  ConsumerState<_DeleteVolumeSheet> createState() => _DeleteVolumeSheetState();
}

class _DeleteVolumeSheetState extends ConsumerState<_DeleteVolumeSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(resourcesRepositoryProvider)
          .removeVolume(widget.serverId, widget.volume.name);
      if (!mounted) return;
      // 先取 messenger 再 pop：pop 之后本 State 的 context 已失效。
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(
        SnackBar(content: Text('已删除数据卷 ${widget.volume.name}')),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('删除数据卷', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            widget.volume.name,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          if (widget.volume.mountpoint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.volume.mountpoint,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '卷里的数据会一起删除，无法恢复。'
            '如果容器仍引用它（包括已停止的容器），面板会拒绝删除并告诉你容器名。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              '删除失败：$_error',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          if (_busy)
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('正在删除…'),
              ],
            )
          else
            HoldToConfirm(
              label: '按住 1.5 秒删除',
              icon: Icons.delete_outline,
              onConfirmed: _delete,
            ),
        ],
      ),
    );
  }
}

/// Docker 空间清理层。
///
/// 打开时先 `docker system df` 展示「占多少 / 能回收多少」，用户勾选目标后
/// 长按执行。默认不勾任何项——破坏性操作不预选，避免「点了确定就删了」。
Future<void> showDockerCleanupSheet(
  BuildContext context, {
  required int serverId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DockerCleanupSheet(serverId: serverId),
  );
}

class _DockerCleanupSheet extends ConsumerStatefulWidget {
  const _DockerCleanupSheet({required this.serverId});

  final int serverId;

  @override
  ConsumerState<_DockerCleanupSheet> createState() =>
      _DockerCleanupSheetState();
}

class _DockerCleanupSheetState extends ConsumerState<_DockerCleanupSheet> {
  /// 勾选的目标。三个键与后端 `docker.PruneTarget` 一致。
  final Set<String> _selected = <String>{};

  bool _busy = false;
  String? _error;
  List<DockerPruneOutcome>? _results;

  static const _targets = <String, String>{
    'images': '悬空镜像（无标签、无容器引用）',
    'volumes': '未使用卷（没有容器引用）',
    'build_cache': '构建缓存',
  };

  Future<void> _prune() async {
    setState(() {
      _busy = true;
      _error = null;
      _results = null;
    });
    try {
      final results = await ref.read(resourcesRepositoryProvider).prune(
            widget.serverId,
            targets: _selected.toList(growable: false),
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = results;
      });
      // 清理后镜像/卷列表与占用统计都变了，统一失效。
      ref.invalidate(diskUsageProvider(widget.serverId));
      ref.invalidate(imagesProvider(widget.serverId));
      ref.invalidate(volumesProvider(widget.serverId));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiError(e);
      });
    }
  }

  /// docker 的类型名转中文；未知类型原样返回，不做猜测。
  static String _typeLabel(String type) {
    switch (type) {
      case 'Images':
        return '镜像';
      case 'Containers':
        return '容器';
      case 'Local Volumes':
        return '本地卷';
      case 'Build Cache':
        return '构建缓存';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = ref.watch(diskUsageProvider(widget.serverId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('清理 Docker 空间', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '只清理「没有容器引用」的资源，正在使用的不会被删。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: usage.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('正在读取 docker system df…'),
                    ],
                  ),
                ),
                error: (e, _) => Text(
                  '读取占用失败：${describeApiError(e)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
                data: (rows) => SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final row in rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 76,
                                child: Text(
                                  _typeLabel(row.type),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '${row.size}${row.totalCount.isEmpty ? '' : ' · ${row.totalCount} 项'}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                              Text(
                                row.reclaimable.isEmpty
                                    ? '—'
                                    : '可回收 ${row.reclaimable}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 24),
            for (final entry in _targets.entries)
              CheckboxListTile(
                value: _selected.contains(entry.key),
                onChanged: _busy || _results != null
                    ? null
                    : (checked) {
                        setState(() {
                          if (checked ?? false) {
                            _selected.add(entry.key);
                          } else {
                            _selected.remove(entry.key);
                          }
                        });
                      },
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(entry.value),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                '清理失败：$_error',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            if (_results != null) ...[
              const SizedBox(height: 8),
              for (final r in _results!)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${r.label}：已清理')),
                      Text(
                        r.reclaimed.isEmpty ? '未报告回收量' : '回收 ${r.reclaimed}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 16),
            if (_busy)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在清理…'),
                ],
              )
            else if (_results != null)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              )
            else
              HoldToConfirm(
                label: _selected.isEmpty
                    ? '先勾选要清理的项目'
                    : '按住 1.5 秒清理（${_selected.length} 项）',
                icon: Icons.cleaning_services_outlined,
                // 未勾选任何项时禁用长按：空 targets 后端也会 400。
                enabled: _selected.isNotEmpty,
                onConfirmed: _prune,
              ),
          ],
        ),
      ),
    );
  }
}
