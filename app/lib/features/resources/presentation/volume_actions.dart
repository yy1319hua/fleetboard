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

/// 一次清理的结果摘要。
///
/// 只用于给调用方弹一句 SnackBar；**provider 失效在弹层内部完成**，
/// 不靠返回值驱动——用户长按松手后顺手把弹层拖掉时，
/// `showModalBottomSheet` 返回 null，靠返回值做失效就会漏刷。
class DockerCleanupRun {
  const DockerCleanupRun({
    required this.outcomes,
    required this.deletedTotal,
    required this.releasedBytes,
  });

  final List<DockerPruneOutcome> outcomes;

  /// 各项 deleted_count 之和；后端未报告的项不计入（不猜 0）。
  final int deletedTotal;

  /// 各项 reclaimed 换算后之和；一项都解析不出时为 0。
  final int releasedBytes;

  bool get deletedSomething => deletedTotal > 0;
}

/// Docker 空间清理层。清理完成后返回结果摘要（用户中途关闭则为 null）。
///
/// 打开时先 `docker system df` 展示「占多少 / 能回收多少」，用户勾选目标后
/// 长按执行。默认不勾任何项——破坏性操作不预选，避免「点了确定就删了」。
Future<DockerCleanupRun?> showDockerCleanupSheet(
  BuildContext context, {
  required int serverId,
}) {
  return showModalBottomSheet<DockerCleanupRun>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DockerCleanupSheet(serverId: serverId),
  );
}

/// 清理目标的一项规格。key 与后端 `docker.PruneTarget` 一致。
class _PruneTargetSpec {
  const _PruneTargetSpec(this.key, this.title, this.hint);

  final String key;
  final String title;
  final String hint;
}

class _DockerCleanupSheet extends ConsumerStatefulWidget {
  const _DockerCleanupSheet({required this.serverId});

  final int serverId;

  @override
  ConsumerState<_DockerCleanupSheet> createState() =>
      _DockerCleanupSheetState();
}

class _DockerCleanupSheetState extends ConsumerState<_DockerCleanupSheet> {
  /// 勾选的目标。
  final Set<String> _selected = <String>{};

  /// 提前抓一个 ProviderContainer：它的生命周期比弹层路由长，
  /// 弹层被拖走/被 pop 后 invalidate 仍然生效。
  ///
  /// 旧实现用 `if (!mounted) return;` 提前返回，把后面的 invalidate 一起跳过了——
  /// 长按松手后手指顺势把弹层拖掉，列表就永远停在旧数据，用户看到的正是
  /// 「提示已清理、卷还在列表里」。
  late final ProviderContainer _container =
      ProviderScope.containerOf(context, listen: false);

  bool _busy = false;
  String? _error;
  List<DockerPruneOutcome>? _results;
  DockerCleanupRun? _run;

  static const _specs = <_PruneTargetSpec>[
    _PruneTargetSpec('images', '悬空镜像', '无 tag、无容器引用'),
    // 「含命名卷」必须写出来：命名卷只要无容器引用就会被 -a 删掉。
    _PruneTargetSpec('volumes', '未使用卷', '没有容器引用，含命名卷（会删除卷内数据）'),
    _PruneTargetSpec('build_cache', '构建缓存', 'docker builder prune'),
  ];

  Future<void> _prune() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcomes = await ref.read(resourcesRepositoryProvider).prune(
            widget.serverId,
            targets: _selected.toList(growable: false),
          );
      final run = DockerCleanupRun(
        outcomes: outcomes,
        deletedTotal: outcomes.fold<int>(
          0,
          (sum, r) => sum + (r.failed ? 0 : r.actualDeletedCount),
        ),
        releasedBytes: outcomes.fold<int>(
          0,
          (sum, r) => sum + (parseDockerSizeBytes(r.reclaimed) ?? 0),
        ),
      );
      // 先失效再管 UI：不管弹层之后是活着、被 pop 还是被拖掉，
      // 列表都已在取新数据。
      _invalidateAll();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = outcomes;
        _run = run;
      });
    } on Object catch (e) {
      // 整个请求失败时磁盘上可能已经删了一半，更需要刷新列表，
      // 否则用户会看到「报了错但卷没了」。
      _invalidateAll();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeApiError(e);
      });
    }
  }

  void _invalidateAll() {
    final id = widget.serverId;
    _container.invalidate(diskUsageProvider(id));
    _container.invalidate(imagesProvider(id));
    _container.invalidate(volumesProvider(id));
    _container.invalidate(unusedVolumesProvider(id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = ref.watch(diskUsageProvider(widget.serverId));

    return PopScope(
      // 清理进行中不许侧滑/返回：SSH 上 prune 常跑十几秒，
      // 中途关掉用户就看不到结果了（列表仍会刷新，见 _invalidateAll）。
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: SingleChildScrollView(
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
                _DfSummary(usage: usage),
                const Divider(height: 24),
                for (final spec in _specs) ...[
                  CheckboxListTile(
                    value: _selected.contains(spec.key),
                    onChanged: _busy || _results != null
                        ? null
                        : (checked) {
                            setState(() {
                              if (checked ?? false) {
                                _selected.add(spec.key);
                              } else {
                                _selected.remove(spec.key);
                              }
                            });
                          },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(spec.title),
                    subtitle: Text(
                      spec.hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // 勾选「未使用卷」才挂载预览：没人 watch → autoDispose 不发请求。
                  if (spec.key == 'volumes' && _selected.contains('volumes'))
                    _UnusedVolumePreview(
                      serverId: widget.serverId,
                      locked: _busy || _results != null,
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '清理失败：$_error',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                  Text(
                    '部分项目可能已删除成功，请下拉刷新列表确认。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_results != null) _CleanupResults(run: _run!, results: _results!),
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
                      Text('正在清理…（不要关闭）'),
                    ],
                  )
                else if (_results != null)
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          _results = null;
                          _run = null;
                          _selected.clear();
                        }),
                        child: const Text('再清一次'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(_run),
                        child: const Text('完成'),
                      ),
                    ],
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
        ),
      ),
    );
  }
}

/// `docker system df` 摘要。
class _DfSummary extends StatelessWidget {
  const _DfSummary({required this.usage});

  final AsyncValue<List<DockerDiskUsage>> usage;

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
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return ConstrainedBox(
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
          style: muted?.copyWith(color: theme.colorScheme.error),
        ),
        data: (rows) => SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                            // 「可回收」是 docker 自己的算法，不是「本页会删掉的量」。
                            : 'Docker 认为可回收 ${row.reclaimable}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              // 镜像口径必须显式标注：df 的镜像行含「有 tag 但无容器引用」的镜像，
              // 而「悬空镜像」只清无 tag 的，数字对不上是必然的。
              if (rows.any((r) => r.type.toLowerCase() == 'images'))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '注：镜像行包含「有 tag 但无容器引用」的镜像；本页「悬空镜像」'
                    '只清无 tag 的，所以回收量会小于这里的数字。'
                    '有 tag 的镜像请在镜像列表里逐个删除。',
                    style: muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 未使用卷预览：勾选即拉一次，执行前把「会删哪些卷」摊开。
class _UnusedVolumePreview extends ConsumerWidget {
  const _UnusedVolumePreview({required this.serverId, required this.locked});

  final int serverId;
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final provider = unusedVolumesProvider(serverId);
    final state = ref.watch(provider);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Container(
      margin: const EdgeInsets.only(left: 40, bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: state.when(
        loading: () => Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('正在列出未使用的卷…', style: muted),
          ],
        ),
        error: (e, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '无法预览将被删除的卷：${describeApiError(e)}',
              style: muted?.copyWith(color: theme.colorScheme.error),
            ),
            // 预览失败 ≠ 不能清理：不阻断主流程，但要说明「你看不到会删哪些」。
            Text('仍可继续清理，但你看不到会删哪些卷。', style: muted),
            if (!locked)
              TextButton.icon(
                onPressed: () => ref.invalidate(provider),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试预览'),
              ),
          ],
        ),
        data: (preview) {
          if (preview.volumes.isEmpty) {
            return Text(_emptyReason(preview), style: muted);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将删除以下 ${preview.volumes.length} 个卷（卷内数据一并删除）：',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (final v in preview.volumes.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    v.composeProject.isEmpty
                        ? '· ${v.name}'
                        : '· ${v.name}（compose 项目 ${v.composeProject}）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              if (preview.volumes.length > 6)
                Text('…另有 ${preview.volumes.length - 6} 个', style: muted),
            ],
          );
        },
      ),
    );
  }

  /// 空态必须说「为什么空」，否则用户只会觉得界面坏了。
  static String _emptyReason(DockerVolumePreview p) {
    if (p.totalCount == 0) {
      return '这台机器上没有任何数据卷，没有可清理的卷。';
    }
    return '没有可自动清理的卷：共 ${p.totalCount} 个卷，全部仍被容器引用'
        '（含已停止容器）。要删除某个卷，请关闭本页后在卷列表长按那一行单独删除。';
  }
}

/// 清理结果：区分「真删了」「没有可清理项」「单项失败」「后端未报告」。
class _CleanupResults extends StatelessWidget {
  const _CleanupResults({required this.run, required this.results});

  final DockerCleanupRun run;
  final List<DockerPruneOutcome> results;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = results.where((r) => r.failed).toList(growable: false);
    final unreported =
        results.any((r) => !r.failed && !r.reported && !r.deletedNothing);

    final String headline;
    if (run.deletedSomething) {
      // 体积只做补充：删除 0B 的空卷是合法结果，成果必须由「已删除 N 项」表达。
      headline =
          '已删除 ${run.deletedTotal} 项 · 释放 ${formatSizeBytes(run.releasedBytes)}';
    } else if (failed.isNotEmpty) {
      headline = '清理未完成';
    } else if (unreported) {
      // 旧后端没报删除项：绝不能说「没有可清理的资源」。
      headline = '清理已执行，但后端未报告删除项';
    } else {
      headline = '没有可清理的资源';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(headline, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final r in results) _row(context, r),
        if (unreported)
          Text(
            '请关闭后下拉刷新列表确认。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, DockerPruneOutcome r) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (r.failed) {
      // 单项失败：后端文案原样展示（里面常带容器名/原因），不改写。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.label}：清理失败', style: theme.textTheme.bodySmall),
                  Text(
                    r.error,
                    style: muted?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (r.deletedNothing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.label}：没有可清理的', style: theme.textTheme.bodySmall),
                  Text(_emptyReason(r.target), style: muted),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (!r.reported) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(Icons.help_outline, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${r.label}：已执行，未报告删除项',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (r.reclaimed.isNotEmpty) Text('回收 ${r.reclaimed}', style: muted),
          ],
        ),
      );
    }

    final names = r.deletedItems.take(3).join('、');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.label}：已删除 ${r.actualDeletedCount} 项'
                  '${r.reclaimed.isEmpty ? '' : ' · 释放 ${r.reclaimed}'}',
                  style: theme.textTheme.bodySmall,
                ),
                if (names.isNotEmpty)
                  Text(
                    r.deletedItems.length > 3 ? '$names 等' : names,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「一项都没删」的原因解释。用 docker 的真实规则，不写套话。
  static String _emptyReason(String target) {
    switch (target) {
      case 'images':
        return '悬空镜像指「无 tag 且无容器引用」的镜像。'
            'df 里的镜像可回收量还包含有 tag 但没被引用的镜像，'
            '那些不会被这一项清掉——要在镜像列表里逐个删除。';
      case 'volumes':
        return '所有卷都仍被容器引用（已停止的容器也算）。'
            '命名卷本身不会被忽略，但只要有容器在用就删不掉；'
            '要删请在卷列表长按那一行。';
      case 'build_cache':
        return '没有可清理的构建缓存（已清空，或从未用过 BuildKit 缓存）。';
      default:
        return '这一项没有可清理的内容。';
    }
  }
}
