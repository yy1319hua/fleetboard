import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants.dart';
import '../../../core/http/envelope.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/status_dot.dart';
import '../application/auth_notifier.dart';

/// 登录页（M9.2 落地，M10.2 收敛）。
///
/// 只保留用户名 + 密码：服务器地址由 [AppConfig] 内置默认值提供，
/// 底部以只读小字展示当前连的是哪台机器。
///
/// 换址走隐藏入口（连续点击标题 [_tapsToReveal] 次）：保存前会探测目标地址的
/// `/api/health`，探测失败不落盘，避免一次误触把客户端指到不可达的域名上。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  /// 当前生效基址（底部只读展示用）。
  String _activeBaseUrl = AppConfig.defaultBaseUrl;

  /// 隐藏改址入口：标题连点计数与上次点击时刻（超窗口自动重置）。
  static const int _tapsToReveal = 7;
  static const Duration _tapWindow = Duration(seconds: 2);
  int _tapCount = 0;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadActiveBaseUrl();
    ref.read(secureStoreProvider).readUsername().then((v) {
      if (v != null && mounted) _usernameController.text = v;
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadActiveBaseUrl() async {
    final stored = await ref.read(secureStoreProvider).readBaseUrl();
    final effective = AppConfig.normalize(
      (stored != null && stored.isNotEmpty) ? stored : AppConfig.defaultBaseUrl,
    );
    if (mounted) setState(() => _activeBaseUrl = effective);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    // 登录：落定后（loading -> session/error）再决定是否跳转。
    await ref.read(authNotifierProvider.notifier).login(
          username: username,
          password: password,
        );
    if (mounted && ref.read(authNotifierProvider).session != null) {
      context.go('/overview');
    }
  }

  /// 标题连点计数：达到阈值打开改址对话框。
  void _onTitleTap() {
    final now = DateTime.now();
    if (now.difference(_lastTapAt) > _tapWindow) _tapCount = 0;
    _lastTapAt = now;
    _tapCount++;
    if (_tapCount >= _tapsToReveal) {
      _tapCount = 0;
      _openServerDialog();
    }
  }

  /// 探测 `{base}/api/health`：HTTP 可达且返回统一信封（code == 0）才算有效地址。
  Future<bool> _probeHealth(String baseUrl) async {
    final dio = createPlainDio()
      ..options.connectTimeout = const Duration(seconds: 6)
      ..options.receiveTimeout = const Duration(seconds: 6);
    try {
      final resp = await dio.get<dynamic>('$baseUrl/api/health');
      final data = resp.data;
      return data is Map && data['code'] == 0;
    } on Object {
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  Future<void> _openServerDialog() async {
    final controller = TextEditingController(text: _activeBaseUrl);
    final dialogFormKey = GlobalKey<FormState>();
    bool probing = false;
    String? errorText;

    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('服务器地址'),
            content: Form(
              key: dialogFormKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextFormField(
                    controller: controller,
                    enabled: !probing,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://your-fleetboard.example.com',
                      errorText: errorText,
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return '请输入服务器地址';
                      }
                      if (!AppConfig.looksValid(v)) {
                        return '请输入完整地址（含 http:// 或 https://）';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '保存前会校验该地址是否可访问。',
                    style: Theme.of(ctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: probing ? null : () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: probing
                    ? null
                    : () async {
                        if (!dialogFormKey.currentState!.validate()) return;
                        setDialogState(() {
                          probing = true;
                          errorText = null;
                        });
                        final target = AppConfig.normalize(controller.text);
                        final reachable = await _probeHealth(target);
                        if (!ctx.mounted) return;
                        if (reachable) {
                          Navigator.of(ctx).pop(target);
                        } else {
                          setDialogState(() {
                            probing = false;
                            errorText = '该地址无法访问，请确认是否正确';
                          });
                        }
                      },
                child: probing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    controller.dispose();
    if (saved == null || !mounted) return;
    await ref.read(secureStoreProvider).writeBaseUrl(saved);
    if (!mounted) return;
    setState(() => _activeBaseUrl = saved);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('服务器地址已更新')),
    );
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
                    // 隐藏改址入口：连点此标题 7 次。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _onTitleTap,
                      child: Text(
                        '随身扳手 · 应急运维',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(color: AppColors.text),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
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
                    const SizedBox(height: AppSpacing.lg),
                    Center(
                      child: Text(
                        _activeBaseUrl.isEmpty
                            ? '未配置服务器地址'
                            : '服务器 ${AppConfig.hostOf(_activeBaseUrl)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.muted),
                      ),
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
