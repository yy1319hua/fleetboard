import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../application/account_notifier.dart';
import '../domain/account_identity.dart';

/// 账户页：看当前身份，改用户名，去改密码。
///
/// 为什么要把「用户名」和「密码」拆成两张卡并各写一句说明：
/// 用户对两者的心智模型通常是「都是账号的一部分，改哪个都可能把我踢下线」。
/// 事实是：用户名只影响**下次登录时输入什么**（JWT 里没有用户名，改名不重签
/// 令牌、其他设备不掉线）；密码才会让 `token_ver` 自增，把其他设备全部下线。
/// 这层差异不写出来，用户就会因为「怕掉线」而不敢改名，或者改完密码后
/// 奇怪为什么别的设备要重登。
class AccountPage extends ConsumerWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(authNotifierProvider).session;

    // 无权限态：会话已失效（7 天硬墙过期 / 令牌被吊销）。
    // 此时页面能显示的信息只剩「你是谁」的旧快照，正常操作全都做不了，
    // 所以不摆任何表单，只给一条明确的回头路。
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('账户')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.lock_outline, size: 36, color: AppColors.warn),
                const SizedBox(height: AppSpacing.md),
                Text('登录状态已失效', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '需要重新登录后才能查看或修改账户信息。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: () => context.go('/login'),
                  child: const Text('重新登录'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final username = session.username.isEmpty ? '（未记录）' : session.username;

    return Scaffold(
      appBar: AppBar(title: const Text('账户')),
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
                          username,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontFamily: AppFonts.mono),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '服务器 ${session.baseUrl}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
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
                  Text('用户名', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '用户名只决定你下次登录时用什么名字，不影响已经签发的登录状态：'
                    '改名后本机与其他已登录设备都保持在线，无需重新登录。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _openChangeUsername(context, ref, username),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('修改用户名'),
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
                  Text('密码', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '密码决定能否登录。修改密码会让其他设备全部下线，本机保持登录。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/settings/security'),
                      icon: const Icon(Icons.password_outlined, size: 18),
                      label: const Text('修改密码'),
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

  Future<void> _openChangeUsername(
    BuildContext context,
    WidgetRef ref,
    String currentUsername,
  ) async {
    // 上一次的报错不该跟着进新表单（「一打开就说我错了」）。
    ref.read(accountNotifierProvider.notifier).reset();
    final changed = await showDialog<String>(
      context: context,
      builder: (_) => _ChangeUsernameDialog(currentUsername: currentUsername),
    );
    if (changed == null || changed.isEmpty || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('用户名已改为 $changed，无需重新登录')),
    );
  }
}

/// 改用户名对话框：就地校验 + 密码二次确认。
///
/// 用对话框而不是整页表单：这里只有一个名字、一个密码，跳页会把「我正在改什么」
/// 这条上下文丢掉；而且改名成功后要立刻回到账户页看新名字。
class _ChangeUsernameDialog extends ConsumerStatefulWidget {
  const _ChangeUsernameDialog({required this.currentUsername});

  final String currentUsername;

  @override
  ConsumerState<_ChangeUsernameDialog> createState() =>
      _ChangeUsernameDialogState();
}

class _ChangeUsernameDialogState extends ConsumerState<_ChangeUsernameDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await ref.read(accountNotifierProvider.notifier).changeUsername(
          newUsername: _nameController.text,
          currentPassword: _passwordController.text,
          currentUsername: widget.currentUsername,
        );
    if (!mounted || !ok) return;
    final display = ref.read(accountNotifierProvider).changedUsername ??
        _nameController.text.trim();
    Navigator.of(context).pop(display);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = ref.watch(accountNotifierProvider);
    final busy = account.submitting;

    return AlertDialog(
      title: const Text('修改用户名'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '当前用户名：${widget.currentUsername}',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _nameController,
              autofocus: true,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '新用户名',
                hintText: '字母或数字开头，3–32 位',
                errorText: account.fieldError,
              ),
              validator: (v) => validateUsernameInput(
                v ?? '',
                currentUsername: widget.currentUsername,
              ),
              onChanged: (_) {
                // 一边改一边把旧报错撤掉，否则红字会停在已修好的输入框下面。
                if (account.fieldError != null || account.error != null) {
                  ref.read(accountNotifierProvider.notifier).reset();
                }
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscure,
              enabled: !busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '当前密码',
                hintText: '确认是本人操作',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                ),
              ),
              validator: (v) => (v == null || v.isEmpty) ? '请输入当前密码' : null,
              onFieldSubmitted: (_) {
                if (!busy) _submit();
              },
            ),
            if (account.error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                account.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : _submit,
          child: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认修改'),
        ),
      ],
    );
  }
}
