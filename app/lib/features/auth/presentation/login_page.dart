import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_dot.dart';
import '../application/auth_notifier.dart';

/// 登录页（M9.2 落地）。
///
/// 自分发 App 需用户先填入自己的 fleetboard 地址（base_url）+ 用户名 + 密码。
/// 7 天硬墙过期重登时，base_url / username 已留存，预填以减负。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _baseUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    // 预填已保存的 base_url / username（硬墙重登场景）。
    final store = ref.read(secureStoreProvider);
    store.readBaseUrl().then((v) {
      if (v != null && mounted) _baseUrlController.text = v;
    });
    store.readUsername().then((v) {
      if (v != null && mounted) _usernameController.text = v;
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final baseUrl = _baseUrlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    // 登录：落定后（loading -> session/error）再决定是否跳转。
    await ref.read(authNotifierProvider.notifier).login(
          baseUrl: baseUrl,
          username: username,
          password: password,
        );
    if (mounted && ref.read(authNotifierProvider).session != null) {
      context.go('/overview');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('登录 fleetboard')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Form(
              key: _formKey,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const StatusDot(StatusKind.info, size: 14),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      '随身扳手 · 应急运维',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(color: AppColors.text),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    TextFormField(
                      controller: _baseUrlController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://your-fleetboard.example.com',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入服务器地址' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(labelText: '用户名'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请输入用户名' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入密码' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (auth.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Text(
                          auth.error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.danger),
                        ),
                      ),
                    FilledButton(
                      onPressed: auth.loading ? null : _submit,
                      child: auth.loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.textInverse,
                              ),
                            )
                          : const Text('登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
