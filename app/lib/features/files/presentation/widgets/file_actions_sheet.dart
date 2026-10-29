import 'package:flutter/material.dart';

import '../../domain/file_entry.dart';
import '../../domain/file_kind.dart';
import '../../domain/file_sizes.dart';

/// 文件/目录操作项。
enum FileAction { download, edit, properties, rename, copy, remove }

/// 弹出文件操作菜单。返回 null 表示用户放弃。
///
/// 用底部菜单而不是长按菜单：文件名普遍较长（`nginx-site-default.conf`），
/// 长按浮出的气泡宽度有限，副标题（大小、能否编辑）会被截断。
Future<FileAction?> showFileActions(BuildContext context, FileEntry entry) {
  final theme = Theme.of(context);
  final editable =
      !entry.dir && entry.size <= maxEditableBytes && looksLikeTextFile(entry.name);
  final tooBigToEdit = !entry.dir &&
      entry.size > maxEditableBytes &&
      looksLikeTextFile(entry.name);

  return showModalBottomSheet<FileAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              dense: true,
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${entry.dir ? '目录' : formatBytes(entry.size)} · ${entry.path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const Divider(height: 1),
            if (!entry.dir) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载'),
                onTap: () => Navigator.of(ctx).pop(FileAction.download),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('在线编辑'),
                enabled: editable,
                subtitle: tooBigToEdit
                    ? Text(
                        '${formatBytes(entry.size)}，超过 1MiB 上限，无法在线编辑',
                        style: theme.textTheme.bodySmall,
                      )
                    : null,
                onTap: editable
                    ? () => Navigator.of(ctx).pop(FileAction.edit)
                    : null,
              ),
            ],
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.of(ctx).pop(FileAction.rename),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制到…'),
              onTap: () => Navigator.of(ctx).pop(FileAction.copy),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('属性'),
              onTap: () => Navigator.of(ctx).pop(FileAction.properties),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(
                '删除',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              onTap: () => Navigator.of(ctx).pop(FileAction.remove),
            ),
          ],
        ),
      ),
    ),
  );
}
