import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../application/update_notifier.dart';

/// 关于页（M9.5b）：展示版本号 / 构建号，并提供自分发 APK 的「检查更新 → 安装」闭环。
///
/// 全流程在同一页完成（不弹二级页），避免下载中途离开导致状态丢失。
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(packageInfoProvider);
    final state = ref.watch(updateProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 应用名以系统安装信息为准（Android 取 manifest 的 android:label），
                  // 不在这里再写死一份——否则桌面图标名和关于页标题会各改各的，
                  // 本次「关于页仍显示小写 fleetboard」就是这么来的。
                  Text(
                    info.maybeWhen(
                      data: (v) => v.appName.isEmpty ? 'Fleetboard' : v.appName,
                      orElse: () => 'Fleetboard',
                    ),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _InfoRow(
                    label: '版本',
                    value: info.maybeWhen(
                      data: (v) => v.version,
                      orElse: () => '-',
                    ),
                  ),
                  _InfoRow(
                    label: '构建号',
                    value: info.maybeWhen(
                      data: (v) => v.buildNumber,
                      orElse: () => '-',
                    ),
                  ),
                  _InfoRow(
                    label: '包名',
                    value: info.maybeWhen(
                      data: (v) => v.packageName,
                      orElse: () => '-',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('检查更新', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  _UpdateBody(state: state),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '更新来自 GitHub Releases 的最新 tag：下载后会先比对官方发布的 SHA-256 校验和，'
            '一致才允许安装。首次安装时需在系统弹窗中允许「来自此来源的应用」。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 更新区域：按 [UpdateState] 渲染不同形态（按钮 / 进度 / 结果）。
class _UpdateBody extends ConsumerWidget {
  const _UpdateBody({required this.state});

  final UpdateState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(updateProvider.notifier);
    final theme = Theme.of(context);

    switch (state) {
      case UpdateIdle():
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('尚未检查是否有新版本。'),
            const SizedBox(height: AppSpacing.md),
            _ActionButton(
              label: '检查更新',
              onPressed: () => notifier.check(),
            ),
          ],
        );

      case UpdateChecking():
        return const Row(
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: AppSpacing.md),
            Text('正在检查…'),
          ],
        );

      case UpdateUpToDate s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('当前已是最新版本（${s.current}）。'),
            const SizedBox(height: AppSpacing.md),
            _ActionButton(
              label: '重新检查',
              onPressed: () => notifier.check(),
            ),
          ],
        );

      case UpdateAvailable s:
        final notes = s.release.body?.trim() ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '发现新版本 ${s.release.tagName}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('安装包约 ${_size(s.apkSize)}'),
            if (notes.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.md),
              Text(
                notes,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            _ActionButton(
              label: '下载更新',
              onPressed: () => notifier.download(),
            ),
          ],
        );

      case UpdateDownloading s:
        final pct = (s.progress * 100).toStringAsFixed(0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('正在下载 ${s.release.tagName} … $pct%'),
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(value: s.progress.clamp(0.0, 1.0)),
          ],
        );

      case UpdateVerifying():
        return const Row(
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: AppSpacing.md),
            Text('正在校验安装包（SHA-256）…'),
          ],
        );

      case UpdateReady s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('${s.release.tagName} 校验通过，可以安装。'),
            const SizedBox(height: AppSpacing.md),
            _ActionButton(
              label: '安装',
              onPressed: () => _installAndTip(context, notifier),
            ),
          ],
        );

      case UpdateFailure s:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              s.message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: AppSpacing.md),
            _ActionButton(
              label: '重试',
              onPressed: () => notifier.check(),
            ),
          ],
        );
    }
  }
}

/// 发起安装；未获「未知来源」授权时跳系统设置，并明确告知用户回来后要做什么。
///
/// 不这样做的话，跳走再回来页面毫无变化，用户不知道是自己没授权还是安装失败了。
Future<void> _installAndTip(BuildContext context, UpdateNotifier notifier) async {
  final ok = await notifier.install();
  if (ok || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('尚未允许安装未知应用。请在系统设置中开启后，返回本页再次点击「安装」。'),
      duration: Duration(seconds: 6),
    ),
  );
}

/// 触控目标统一 ≥44px（DESIGN.md §7 硬指标）。
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: touchMin,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, touchMin),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        ),
        child: Text(label),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// 体积展示：不足 1MB 用 KB，否则用 MB 保留一位小数。
String _size(int bytes) {
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}
