import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';

/// 设置根页（Tab 3）。
///
/// M11 起不再是只读展示：本页只承担「分组入口」，具体配置在各自子页完成。
/// 子页一律全屏 push（`parentNavigatorKey: root`）——360dp 宽下软键盘弹起只剩
/// 约 316dp 可视高度，留在 Shell 内会让「表单 + 保存条」被键盘压掉。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authNotifierProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          _AccountCard(
            baseUrl: auth.session?.baseUrl ?? AppConfig.defaultBaseUrl,
            username: auth.session?.username ?? '-',
          ),
          const SizedBox(height: AppSpacing.lg),
          _Group(
            title: '面板配置',
            children: <Widget>[
              _EntryTile(
                icon: Icons.notifications_active_outlined,
                title: '通知推送',
                subtitle: 'PushPlus 令牌与测试推送',
                onTap: () => context.push('/settings/push'),
              ),
              _EntryTile(
                icon: Icons.monitor_heart_outlined,
                title: '采集与保留',
                subtitle: '采集间隔 / 保留天数 / 离线阈值 / Compose 根目录',
                onTap: () => context.push('/settings/monitor'),
              ),
              _EntryTile(
                icon: Icons.rule_outlined,
                title: '告警规则',
                subtitle: 'CPU / 内存 / 磁盘阈值与通知开关',
                onTap: () => context.push('/settings/alert-rules'),
              ),
              _EntryTile(
                icon: Icons.history_outlined,
                title: '操作审计',
                subtitle: '谁在什么时候对哪台机器做了什么',
                onTap: () => context.push('/settings/audit'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Group(
            title: '服务器',
            children: <Widget>[
              _EntryTile(
                icon: Icons.dns_outlined,
                title: '服务器纳管',
                subtitle: '新增 / 测试连接 / 删除',
                onTap: () => context.push('/settings/servers'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Group(
            title: '账户',
            children: <Widget>[
              _EntryTile(
                icon: Icons.shield_outlined,
                title: '账户与安全',
                subtitle: '修改用户名 / 修改密码 / 注销所有会话',
                onTap: () => context.push('/settings/account'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Group(
            title: '面板维护',
            children: <Widget>[
              _EntryTile(
                icon: Icons.system_update_outlined,
                title: '面板更新',
                subtitle: '检查并升级当前连接的面板本体',
                onTap: () => context.push('/settings/upgrade'),
              ),
              _EntryTile(
                icon: Icons.upgrade_outlined,
                title: '升级历史',
                subtitle: '每次升级的版本、耗时与结果',
                onTap: () => context.push('/settings/upgrade/history'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _Group(
            title: '应用',
            children: <Widget>[
              _EntryTile(
                icon: Icons.info_outline,
                title: '关于',
                subtitle: 'App 版本信息与更新',
                onTap: () => context.push('/settings/about'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.tonal(
            onPressed: () => _confirmLogout(context, ref),
            child: const Text('登出'),
          ),
          const SizedBox(height: AppSpacing.lg),
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

/// 顶部账户卡：当前连接的面板地址与登录用户名（只读）。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.baseUrl, required this.username});

  final String baseUrl;
  final String username;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: <Widget>[
            const Icon(Icons.dns_outlined, color: AppColors.accent, size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    username,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    host.isEmpty ? '未配置服务器地址' : host,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.xs,
            bottom: AppSpacing.sm,
          ),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppColors.faint,
              letterSpacing: 0.6,
            ),
          ),
        ),
        Card(
          child: Column(
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) const Divider(height: 1, indent: AppSpacing.lg),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: touchMin,
      leading: Icon(icon, color: AppColors.muted),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: AppColors.faint),
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.faint),
      onTap: onTap,
    );
  }
}
