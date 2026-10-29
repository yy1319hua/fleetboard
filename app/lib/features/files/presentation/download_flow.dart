import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/errors/api_exception.dart';
import '../application/download_service.dart';
import '../data/files_repository.dart';
import '../domain/file_sizes.dart';
import '../domain/files_error.dart';

/// 下载一个远端文件，并在下载结束后给出「打开 / 分享 / 另存到…」。
///
/// 这段流程刻意写在 UI 层而不是 repository：它要弹进度框、要 cancel、
/// 要把结果交给系统（SAF / 分享面板），这些都不是「取数据」的职责。
Future<void> startFileDownload(
  BuildContext context,
  WidgetRef ref, {
  required int serverId,
  required String remotePath,
  required String name,
  required int totalBytes,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final meter = _TransferMeter();
  final cancelToken = CancelToken();
  var dialogOpen = false;

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TransferDialog(
        name: name,
        meter: meter,
        onCancel: () {
          if (!cancelToken.isCancelled) cancelToken.cancel('已取消下载');
        },
      ),
    ).then((_) => dialogOpen = false),
  );
  dialogOpen = true;

  try {
    final result = await DownloadService(ref.read(filesRepositoryProvider)).run(
      serverId,
      remotePath,
      name: name,
      totalBytes: totalBytes,
      cancelToken: cancelToken,
      onProgress: meter.advance,
    );
    if (dialogOpen) navigator.pop();
    if (!context.mounted) return;
    await _showResultSheet(context, result, messenger);
  } on Object catch (e) {
    if (dialogOpen) navigator.pop();
    final isCancel = cancelToken.isCancelled;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          isCancel ? '已取消下载' : '下载失败：${describeFilesError(e, path: remotePath)}',
        ),
      ),
    );
  }
  // 不 dispose [meter]：进度框的退场动画还在读它，此时 dispose 会抛
  // "used after being disposed"。一次性对象交给 GC 即可。
}

Future<void> _showResultSheet(
  BuildContext context,
  DownloadedFile result,
  ScaffoldMessengerState messenger,
) async {
  final canSaveAs = result.bytes != null;
  final action = await showModalBottomSheet<_ResultAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(
                result.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${formatBytes(result.size)} · 已存到 App 临时目录',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开'),
              onTap: () => Navigator.of(ctx).pop(_ResultAction.open),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享'),
              subtitle: const Text('通过系统分享面板存到网盘/聊天工具'),
              onTap: () => Navigator.of(ctx).pop(_ResultAction.share),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('另存到…'),
              enabled: canSaveAs,
              // 大文件走流式落盘，内存里没有字节；把 200MB 读进内存再交给
              // SAF 就是主动制造一次 OOM，所以这里直接说明改用分享保存。
              subtitle: Text(
                canSaveAs ? '选择一个文件夹保存' : '文件较大，请用「分享」保存到目标位置',
              ),
              onTap: canSaveAs
                  ? () => Navigator.of(ctx).pop(_ResultAction.saveAs)
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('关闭'),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
    },
  );
  if (action == null) return;

  switch (action) {
    case _ResultAction.open:
      final opened = await OpenFilex.open(result.file.path);
      if (opened.type != ResultType.done) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('这台设备上没有能打开该类型文件的应用，可以改用「分享」保存到别处'),
          ),
        );
      }
    case _ResultAction.share:
      try {
        await Share.shareXFiles(
          <XFile>[XFile(result.file.path)],
          subject: result.name,
          text: result.name,
        );
      } on Object catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(_systemFailure('分享', e))),
        );
      }
    case _ResultAction.saveAs:
      final bytes = result.bytes;
      if (bytes == null) return;
      try {
        // Android 上走 SAF：用户选目标位置，App 不需要存储权限。
        final saved = await FilePicker.platform.saveFile(
          dialogTitle: '另存到…',
          fileName: result.name,
          bytes: bytes,
        );
        if (saved == null) return;
        messenger.showSnackBar(const SnackBar(content: Text('已保存')));
      } on Object catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text(_systemFailure('保存', e))),
        );
      }
  }
}

/// 系统面板（分享/SAF）失败时的文案。
///
/// 这类错误来自平台侧（PlatformException），用 [describeApiError] 解会得到
/// 「请求失败，请稍后重试」——既不对也不可执行。
String _systemFailure(String action, Object error) {
  if (error is PlatformException) {
    final detail = error.message?.trim();
    return '$action失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
  }
  return '$action失败：${describeApiError(error)}';
}

enum _ResultAction { open, share, saveAs }

/// 下载进度的可变快照。
class _Transfer {
  const _Transfer(this.received, this.total, this.bytesPerSec);

  final int received;

  /// 0 表示服务端没给 Content-Length（进度条改为不确定态）。
  final int total;
  final int bytesPerSec;

  double? get ratio => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class _TransferMeter extends ValueNotifier<_Transfer> {
  _TransferMeter() : super(const _Transfer(0, 0, 0));

  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;

  void advance(int received, int? total) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTick).inMilliseconds;
    var speed = value.bytesPerSec;
    // 250ms 内的抖动不重算，否则数字会疯狂上下跳。
    if (elapsed >= 250) {
      final instant = ((received - _lastBytes) * 1000 / elapsed).round();
      speed = speed == 0 ? instant : (speed * 0.6 + instant * 0.4).round();
      _lastTick = now;
      _lastBytes = received;
    }
    value = _Transfer(received, total ?? 0, speed);
  }
}

class _TransferDialog extends StatelessWidget {
  const _TransferDialog({
    required this.name,
    required this.meter,
    required this.onCancel,
  });

  final String name;
  final ValueNotifier<_Transfer> meter;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('正在下载'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<_Transfer>(
            valueListenable: meter,
            builder: (context, value, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: value.ratio),
                  const SizedBox(height: 8),
                  Text(
                    '${formatBytes(value.received)}'
                    '${value.total > 0 ? ' / ${formatBytes(value.total)}' : ''}'
                    ' · ${formatBandwidth(value.bytesPerSec)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: onCancel, child: const Text('取消')),
      ],
    );
  }
}
