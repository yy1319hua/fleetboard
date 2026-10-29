import 'package:flutter/material.dart';

import '../../../core/widgets/diff_view.dart';

/// 改动预览确认层（保存写回、剪贴板整份导入共用）。
///
/// 为什么所有写操作都必须先过这一层：compose 文件一旦写错，`docker compose up`
/// 会直接起不来，而用户手上往往没有备份。行级 diff 能在**确认之前**告出
/// 「我明明只改了一个端口，为什么 YAML 少了两行」这类问题（例如误删缩进），
/// 弹一个「确认写入？」的纯文本弹窗是给不出这个信息量的。
///
/// 返回 true 表示用户确认。
Future<bool> showDiffConfirm(
  BuildContext context, {
  required String title,
  required String before,
  required String after,
  required String confirmLabel,
  String? warning,
  String? subtitle,
}) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final height = MediaQuery.sizeOf(sheetContext).height;
      return SizedBox(
        height: height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (warning != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 18,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              warning,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            // DiffView 内部是 Column + Expanded(ListView)，必须给有界高度。
            Expanded(child: DiffView(before: before, after: after)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  return confirmed ?? false;
}
