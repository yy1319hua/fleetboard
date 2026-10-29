import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/hold_to_confirm.dart';
import '../data/resources_repository.dart';
import '../domain/docker_resource.dart';

/// 拉取镜像。成功返回 true（调用方据此刷新列表）。
///
/// 为什么是弹层内的完整状态机而不是「提交后转圈 + SnackBar」：
/// `docker pull` 可能跑几分钟，用户需要看到进度在动、需要能中途放弃，
/// 也需要在结束后看到 docker 的真实输出（镜像不存在、私有仓库鉴权失败等
/// 都只体现在输出里，后端只在进程非零退出时给一句 502 文案）。
Future<bool> showPullImageDialog(
  BuildContext context, {
  required int serverId,
}) async {
  final pulled = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PullImageDialog(serverId: serverId),
  );
  return pulled ?? false;
}

class _PullImageDialog extends ConsumerStatefulWidget {
  const _PullImageDialog({required this.serverId});

  final int serverId;

  @override
  ConsumerState<_PullImageDialog> createState() => _PullImageDialogState();
}

enum _Phase { input, running, done, failed }

class _PullImageDialogState extends ConsumerState<_PullImageDialog> {
  final TextEditingController _controller = TextEditingController();
  final CancelToken _cancelToken = CancelToken();

  _Phase _phase = _Phase.input;
  String? _error;
  String _output = '';

  @override
  void dispose() {
    _controller.dispose();
    // 用户直接关掉弹层时也要断掉请求，否则 SSH 会话和 dio 连接会一直挂着。
    if (!_cancelToken.isCancelled) _cancelToken.cancel('页面已关闭');
    super.dispose();
  }

  Future<void> _submit() async {
    final error = validateImageReference(_controller.text);
    if (error != null) {
      setState(() {
        _phase = _Phase.failed;
        _error = error;
        _output = '';
      });
      return;
    }
    setState(() {
      _phase = _Phase.running;
      _error = null;
      _output = '';
    });
    try {
      final output = await ref
          .read(resourcesRepositoryProvider)
          .pullImage(widget.serverId, _controller.text.trim(), cancelToken: _cancelToken);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _output = output.trim();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = describeApiError(e);
      });
    }
  }

  void _cancelWait() {
    if (!_cancelToken.isCancelled) _cancelToken.cancel('用户取消等待');
    if (!mounted) return;
    Navigator.of(context).pop(false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('已停止等待。服务器上的 docker pull 可能仍在后台继续，稍后刷新列表确认。'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _phase == _Phase.running;
    final done = _phase == _Phase.done;
    return AlertDialog(
      title: const Text('拉取镜像'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              enabled: !running && !done,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              onSubmitted: (_) {
                if (_phase == _Phase.input || _phase == _Phase.failed) {
                  _submit();
                }
              },
              decoration: InputDecoration(
                labelText: '镜像名（repo:tag）',
                hintText: 'nginx:alpine',
                helperText: '不写 tag 默认 latest；私有仓库记得带上仓库地址',
                errorText: _phase == _Phase.failed ? _error : null,
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            if (running) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text(
                '正在拉取…大镜像可能要几分钟，请不要退出。',
                style: TextStyle(fontSize: 12),
              ),
            ],
            if (done) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 18, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  const Expanded(child: Text('拉取完成，镜像已在本机。')),
                ],
              ),
              if (_output.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _output,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ],
            if (_phase == _Phase.failed && _error != null) ...[
              const SizedBox(height: 12),
              Text(
                '拉取失败通常是镜像名写错、网络不通，或私有仓库未登录。'
                '确认后在机器上执行 docker pull <镜像名> 可以看到完整报错。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (running)
          TextButton(onPressed: _cancelWait, child: const Text('停止等待'))
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(_phase == _Phase.done),
            child: Text(done ? '完成' : '取消'),
          ),
        if (!running && !done)
          FilledButton(
            onPressed: _submit,
            child: Text(_phase == _Phase.failed ? '重试' : '拉取'),
          ),
      ],
    );
  }
}

/// 删除镜像确认层（长按触发）。
///
/// 删除不可撤销，且会连带影响「用这个镜像重启容器」，所以用 [HoldToConfirm]
/// 而不是二次弹窗：误触时手指抬不起来，条件反射点"确定"在这里不成立。
/// 成功返回 true。
Future<bool> showDeleteImageSheet(
  BuildContext context, {
  required int serverId,
  required DockerImage image,
}) async {
  final deleted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _DeleteImageSheet(
      serverId: serverId,
      image: image,
    ),
  );
  return deleted ?? false;
}

class _DeleteImageSheet extends ConsumerStatefulWidget {
  const _DeleteImageSheet({required this.serverId, required this.image});

  final int serverId;
  final DockerImage image;

  @override
  ConsumerState<_DeleteImageSheet> createState() => _DeleteImageSheetState();
}

class _DeleteImageSheetState extends ConsumerState<_DeleteImageSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final output = await ref
          .read(resourcesRepositoryProvider)
          .removeImage(widget.serverId, widget.image.id);
      if (!mounted) return;
      // 先取 messenger 再 pop：pop 之后本 State 的 context 已失效，
      // 用它去找 ScaffoldMessenger 会抛 "deactivated widget" 异常。
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            output.trim().isEmpty
                ? '已删除 ${widget.image.reference}'
                : '已删除 ${widget.image.reference}：${output.trim().split('\n').first}',
          ),
        ),
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
          Text('删除镜像', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            widget.image.reference,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.image.size} · ${widget.image.createdSince}'
            '${widget.image.isDangling ? ' · 无标签（dangling）' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text(
            '删除后无法恢复；使用该镜像的容器会在下次重启时失败。'
            '后端对"镜像不存在"按成功处理，所以重复删除不会报错。',
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
            const SizedBox(height: 4),
            Text(
              '常见原因是仍有容器在用这个镜像（先停容器），或该镜像没有可用的 ID。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (!widget.image.canDelete)
            Text(
              '这个镜像没有返回 ID，接口没法定位它，因此不能在这里删除。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            )
          else if (_busy)
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
