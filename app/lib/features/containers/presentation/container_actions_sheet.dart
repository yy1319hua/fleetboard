import 'package:flutter/material.dart' hide Container;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/fullscreen_confirm.dart';
import '../application/container_action_controller.dart';
import '../application/containers_notifier.dart';
import '../domain/container.dart';
import '../domain/container_action.dart';

/// 容器操作底部弹层（M9.3 步2）：启动/停止/重启/删除。
///
/// 危险操作（重启/删除）走全屏确认 + 手输容器名前 4 位；普通操作走轻确认。
/// 提交期间置提交锁（禁重复），失败仅提示、不自动重试（B6）。
class ContainerActionsSheet extends ConsumerWidget {
  const ContainerActionsSheet({
    super.key,
    required this.serverId,
    required this.container,
  });

  final int serverId;
  final Container container;

  String get _displayName =>
      container.name.isEmpty ? container.id : container.name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(containerActionControllerProvider) is ActionSubmitting;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _displayName,
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...ContainerActionType.values.map(
              (t) => ListTile(
                enabled: !busy,
                leading: Icon(
                  switch (t) {
                    ContainerActionType.start => Icons.play_arrow_outlined,
                    ContainerActionType.stop => Icons.stop_outlined,
                    ContainerActionType.restart => Icons.restart_alt_outlined,
                    ContainerActionType.rm => Icons.delete_outline,
                  },
                  color: t.dangerous ? AppColors.danger : AppColors.text,
                ),
                title: Text(t.label),
                onTap: busy ? null : () => _onAction(context, ref, t),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    ContainerActionType type,
  ) async {
    // 1) 先行确认（危险操作全屏 + 手输；普通操作轻确认）。
    if (type.dangerous) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => FullscreenConfirm(
            title: '${type.label}容器',
            message: '即将${type.label}容器「$_displayName」，此操作不可逆。',
            expectedToken: _namePrefix(),
          ),
        ),
      );
      if (ok != true || !context.mounted) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${type.label}容器'),
          content: Text('确认${type.label}「$_displayName」？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    }

    // 2) 提交（提交锁：busy 时直接返回 null）。
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final result = await ref
        .read(containerActionControllerProvider.notifier)
        .submit(serverId, container.id, type);

    if (result != null) {
      ref.read(containersProvider(serverId).notifier).refresh();
      messenger.showSnackBar(SnackBar(content: Text('${type.label}成功')));
      if (nav.canPop()) nav.pop();
    } else {
      final state = ref.read(containerActionControllerProvider);
      final msg = state is ActionFailure ? state.message : '操作失败';
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// 容器名前 4 位（不足取实际长度）。
  String _namePrefix() {
    final base = _displayName;
    return base.length <= 4 ? base : base.substring(0, 4);
  }
}
