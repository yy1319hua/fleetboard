import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/status_dot.dart';
import '../../application/upload_queue_notifier.dart';
import '../../domain/file_sizes.dart';
import '../../domain/upload_task.dart';

/// 上传队列悬浮卡片。
///
/// 为什么是悬浮在列表之上而不是独立页面：上传是「边干别的事边等」的任务，
/// 用户要在浏览目录、改配置的同时看到进度。跳页会打断浏览，SnackBar 又撑不住
/// 多任务的暂停/继续操作。
class UploadQueueCard extends ConsumerStatefulWidget {
  const UploadQueueCard({super.key, required this.serverId});

  final int serverId;

  @override
  ConsumerState<UploadQueueCard> createState() => _UploadQueueCardState();
}

class _UploadQueueCardState extends ConsumerState<UploadQueueCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = ref.watch(uploadQueueProvider);
    final mine = queue.forServer(widget.serverId);
    if (mine.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(uploadQueueProvider.notifier);
    final others = queue.tasks.length - mine.length;
    final headline = _headline(mine);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _headlineRow(theme, headline, mine, others, notifier),
              if (!_expanded && headline.status != UploadStatus.done)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: LinearProgressIndicator(
                    value: headline.status == UploadStatus.verifying
                        ? null
                        : headline.progress,
                    minHeight: 3,
                  ),
                ),
              if (_expanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: mine.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _tile(mine[i], notifier),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headlineRow(
    ThemeData theme,
    UploadTask headline,
    List<UploadTask> mine,
    int others,
    UploadQueueNotifier notifier,
  ) {
    final active = mine.where((t) => !t.status.isTerminal).length;
    final paused = mine.where((t) => t.status == UploadStatus.paused).length;
    final done = mine.where((t) => t.status == UploadStatus.done).length;
    final failed = mine.where((t) => t.status == UploadStatus.failed).length;

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: <Widget>[
            StatusDot(_kindOf(headline.status)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _expanded
                        ? '上传队列 · ${mine.length} 项'
                        : headline.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    _summary(headline, active: active, others: others),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '队列操作',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (value) {
                switch (value) {
                  case 'pauseAll':
                    notifier.pauseAll();
                  case 'resumeAll':
                    notifier.resumeAll();
                  case 'clearDone':
                    notifier.clearDone();
                  case 'clearFailed':
                    notifier.clearFailed();
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'pauseAll',
                  enabled: active > 0,
                  child: const Text('全部暂停'),
                ),
                PopupMenuItem<String>(
                  value: 'resumeAll',
                  enabled: paused > 0,
                  child: Text('全部继续${paused > 0 ? '（$paused）' : ''}'),
                ),
                PopupMenuItem<String>(
                  value: 'clearDone',
                  enabled: done > 0,
                  child: Text('清除已完成${done > 0 ? '（$done）' : ''}'),
                ),
                PopupMenuItem<String>(
                  value: 'clearFailed',
                  enabled: failed > 0,
                  child: Text('清除失败项${failed > 0 ? '（$failed）' : ''}'),
                ),
              ],
            ),
            IconButton(
              tooltip: _expanded ? '收起' : '展开',
              icon: Icon(_expanded ? Icons.expand_more : Icons.expand_less),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(UploadTask task, UploadQueueNotifier notifier) {
    final theme = Theme.of(context);
    final showBar = task.status == UploadStatus.uploading ||
        task.status == UploadStatus.verifying ||
        task.status == UploadStatus.paused;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(_kindOf(task.status)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      task.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      _tileSubtitle(task),
                      maxLines: 2,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: task.message != null
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ..._actions(task, notifier),
            ],
          ),
          if (showBar)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
              child: LinearProgressIndicator(
                value: task.status == UploadStatus.verifying
                    ? null
                    : task.progress,
                minHeight: 3,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _actions(UploadTask task, UploadQueueNotifier notifier) {
    switch (task.status) {
      case UploadStatus.uploading:
      case UploadStatus.queued:
        return <Widget>[
          IconButton(
            tooltip: '暂停',
            icon: const Icon(Icons.pause, size: 20),
            onPressed: () => notifier.pause(task.id),
          ),
          IconButton(
            tooltip: '取消',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => notifier.remove(task.id),
          ),
        ];
      case UploadStatus.paused:
        return <Widget>[
          TextButton(
            onPressed: () => notifier.resume(task.id),
            child: const Text('继续'),
          ),
          IconButton(
            tooltip: '取消',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => notifier.remove(task.id),
          ),
        ];
      case UploadStatus.verifying:
        return <Widget>[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ];
      case UploadStatus.done:
      case UploadStatus.failed:
        return <Widget>[
          IconButton(
            tooltip: '移除',
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => notifier.remove(task.id),
          ),
        ];
    }
  }

  static UploadTask _headline(List<UploadTask> mine) {
    for (final status in <UploadStatus>[
      UploadStatus.uploading,
      UploadStatus.verifying,
      UploadStatus.paused,
      UploadStatus.queued,
      UploadStatus.failed,
      UploadStatus.done,
    ]) {
      for (final task in mine) {
        if (task.status == status) return task;
      }
    }
    return mine.first;
  }

  static String _summary(
    UploadTask headline, {
    required int active,
    required int others,
  }) {
    final parts = <String>[
      headline.status.label,
      if (headline.status == UploadStatus.paused && headline.message != null)
        headline.message!
      else if (headline.status == UploadStatus.uploading)
        '${formatPercent(headline.progress)} · '
            '${formatBandwidth(headline.bytesPerSec)} · ${headline.sizeLabel}'
      else if (headline.status == UploadStatus.verifying)
        '正在核对服务端大小…'
      else if (headline.status == UploadStatus.done)
        formatBytes(headline.totalBytes)
      else if (headline.status == UploadStatus.failed)
        headline.message ?? '失败'
      else
        headline.sizeLabel,
      if (active > 1) '共 $active 个在传',
      if (others > 0) '另有 $others 个在其他服务器',
    ];
    return parts.join(' · ');
  }

  static String _tileSubtitle(UploadTask task) {
    switch (task.status) {
      case UploadStatus.uploading:
        return '${formatPercent(task.progress)} · '
            '${formatBandwidth(task.bytesPerSec)} · ${task.sizeLabel}';
      case UploadStatus.verifying:
        return '正在核对服务端大小（${formatBytes(task.totalBytes)}）';
      case UploadStatus.done:
        return '已核对：服务端 ${formatBytes(task.totalBytes)}';
      case UploadStatus.paused:
        return task.message ?? '已暂停';
      case UploadStatus.failed:
        return task.message ?? '失败';
      case UploadStatus.queued:
        return '等待上传 · ${task.dirPath} · ${task.sizeLabel}';
    }
  }

  static StatusKind _kindOf(UploadStatus status) {
    switch (status) {
      case UploadStatus.done:
        return StatusKind.ok;
      case UploadStatus.failed:
        return StatusKind.danger;
      case UploadStatus.paused:
        return StatusKind.warn;
      case UploadStatus.uploading:
      case UploadStatus.verifying:
        return StatusKind.info;
      case UploadStatus.queued:
        return StatusKind.idle;
    }
  }
}
