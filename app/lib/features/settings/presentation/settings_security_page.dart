import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../data/settings_repository.dart';
import 'settings_common.dart';

/// 账户与安全：修改密码、注销所有会话。
///
/// 两个动作都会让服务端的 `token_ver` 自增（旧 refresh 全灭），差别是：
/// - 改密：服务端**同时签发新 token 对**，客户端立刻落盘即可继续用；
/// - 注销所有会话：不签发，本机也必须回到登录页。
/// 若不区分这两者，改密后用户会在下一次静默续期时被无故踢下线。
class SettingsSecurityPage extends ConsumerStatefulWidget {
  const SettingsSecurityPage({super.key});

  @override
  ConsumerState<SettingsSecurityPage> createState() =>
      _SettingsSecurityPageState();
}

class _SettingsSecurityPageState extends ConsumerState<SettingsSecurityPage> {
  final TextEditingController _old = TextEditingController();
  final TextEditingController _new = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _saving = false;
  bool _revoking = false;
  bool _obscure = true;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _old.text.isNotEmpty && _new.text.isNotEmpty && _confirm.text.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = ref.watch(authNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('账户与安全')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('当前账户', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.person_outline,
                          size: 18, color: AppColors.muted),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          auth.session?.username ?? '-',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'JetBrains Mono',
                          ),
                        ),
                      ),
                    ],
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
                  Text('修改密码', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '修改后其他设备上的登录会全部失效，本机保持登录。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _old,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: fieldDecoration('当前密码'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _new,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: fieldDecoration('新密码', helper: '至少 8 位'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _confirm,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: fieldDecoration('再输一次新密码'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                          color: AppColors.faint,
                        ),
                        tooltip: _obscure ? '显示密码' : '隐藏密码',
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          '也可以用系统密码输入法的显示键核对。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.faint),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: (_saving || _revoking || !_canSubmit)
                          ? null
                          : _submit,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('修改密码'),
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
                  Text('会话', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '注销后本机与所有其他设备都需重新登录。设备丢失时用这一项。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: (_saving || _revoking) ? null : _confirmRevoke,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: const BorderSide(color: AppColors.danger),
                      ),
                      child: _revoking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('注销所有会话'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final oldPwd = _old.text;
    final newPwd = _new.text;
    if (newPwd.length < 8) {
      showToast(context, '新密码至少 8 位', isError: true);
      return;
    }
    if (newPwd != _confirm.text) {
      showToast(context, '两次输入的新密码不一致', isError: true);
      return;
    }
    if (newPwd == oldPwd) {
      showToast(context, '新密码不能与当前密码相同', isError: true);
      return;
    }

    setState(() => _saving = true);
    try {
      final token = await ref
          .read(settingsRepositoryProvider)
          .changePassword(oldPassword: oldPwd, newPassword: newPwd);
      // 关键：立刻把新 token 对写进本地，否则旧 refresh 已被吊销，
      // 下一次续期会被判无效 → 用户被踢，却以为「改密码导致掉线」。
      await ref.read(authNotifierProvider.notifier).applyTokenPair(token);
      if (!mounted) return;
      _old.clear();
      _new.clear();
      _confirm.clear();
      setState(() {});
      showToast(context, '密码已修改，其他设备已下线');
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '修改失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmRevoke() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('注销所有会话'),
            content: const Text(
              '本机与所有其他设备都会退出登录，需要重新输入用户名和密码。\n\n'
              '如果只是想退出本机，请返回设置页用「登出」。',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('全部注销'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _revoking = true);
    try {
      await ref.read(settingsRepositoryProvider).revokeSessions();
      if (!mounted) return;
      // 服务端已吊销全部 refresh；本地必须同步清空，否则界面仍停在已登录态。
      await ref.read(authNotifierProvider.notifier).logout();
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '注销失败：${describeApiError(e)}', isError: true);
      setState(() => _revoking = false);
    }
  }
}
