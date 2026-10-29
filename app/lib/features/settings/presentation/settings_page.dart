import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../application/settings_provider.dart';
import '../domain/settings.dart';

/// 设置页（Tab 3，M9.2 落地）。
///
/// 只读展示 GET /api/settings（首版不编辑，标注"首版只读"）。
/// 含登出按钮：确认后调用 logout，路由重定向回登录。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final auth = ref.watch(authNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(
              '首版只读：设置项暂不可编辑，仅展示当前服务器配置。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.accent),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('账户',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  _InfoRow(
                      label: '服务器',
                      value: auth.session?.baseUrl ?? AppConfig.defaultBaseUrl),
                  _InfoRow(label: '用户名', value: auth.session?.username ?? '-'),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          settings.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('设置加载失败：$e',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.danger)),
            ),
            data: (data) => _SettingsList(data: data),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              subtitle: const Text('版本信息与自分发更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/settings/about'),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.tonal(
            onPressed: () => _confirmLogout(context, ref),
            child: const Text('登出'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认登出'),
            content: const Text('将清除本机保存的登录令牌，需重新登录。'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('登出'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed && context.mounted) {
      await ref.read(authNotifierProvider.notifier).logout();
    }
  }
}

class _SettingsList extends StatelessWidget {
  const _SettingsList({required this.data});
  final SettingsResponse data;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('服务器设置',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            ...data.entries.map(
              (e) => _InfoRow(
                label: e.label,
                value: e.displayValue,
                secret: e.isSecret,
              ),
            ),
            const Divider(),
            _InfoRow(label: '主密钥（尾 4 位）', value: data.readonly.keyMasked),
            _InfoRow(label: '服务端口', value: data.readonly.port.toString()),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.secret = false,
  });
  final String label;
  final String value;
  final bool secret;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: secret ? AppColors.accent : AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
