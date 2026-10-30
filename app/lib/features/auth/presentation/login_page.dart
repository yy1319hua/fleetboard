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
import '../application/saved_credentials.dart';

/// 登录页（M9.2 落地，M10.2 收敛，M12 加免密登录）。
///
/// 只保留用户名 + 密码：服务器地址由 [AppConfig] 内置默认值提供，
/// 底部以只读小字展示当前连的是哪台机器。
///
/// 换址走隐藏入口（连续点击标题 [_tapsToReveal] 次）：保存前会探测目标地址的
/// `/api/health`，探测失败不落盘，避免一次误触把客户端指到不可达的域名上。
/// 换址成功会立刻清掉本机保存的密码——旧密码对新服务器没有意义。
///
/// 免密登录（勾选「保存密码」）的三条边界见 [SavedCredentialsNotifier]：
/// 默认不勾、取消即删、连续 3 次失败即删。
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

  /// 「保存密码」勾选态。默认不勾——只有用户自己勾过才允许本机留密码。
  bool _remember = false;

  /// 用户是否亲手改过密码框。
  ///
  /// 自动填充只在「进页面时、且用户还没动过」时发生：把用户刚敲进去的密码
  /// 覆盖成旧的已存密码，比不自动填充糟得多。
  bool _passwordTouched = false;

  /// 隐藏改址入口：标题连点计数与上次点击时刻（超窗口自动重置）。
  static const int _tapsToReveal = 7;
  static const Duration _tapWindow = Duration(seconds: 2);
  int _tapCount = 0;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadActiveBaseUrl();
    _restoreIdentity();
  }

  /// 恢复用户名与已保存的密码（免密登录的「进页面自动填」）。
  ///
  /// 用户名来自 SecureStore（登出不清身份）；密码只在用户勾选过才存在。
  /// 两次读盘都容忍失败：读不出来就是「没存过」，绝不让它变成登录失败。
  Future<void> _restoreIdentity() async {
    String? username;
    try {
      username = await ref.read(secureStoreProvider).readUsername();
    } on Object {
      username = null;
    }
    if (username != null &&
        username.isNotEmpty &&
        mounted &&
        _usernameController.text.isEmpty) {
      _usernameController.text = username;
    }

    final credentials = ref.read(savedCredentialsProvider.notifier);
    await credentials.hydrate();
    if (!mounted) return;
    final snapshot = ref.read(savedCredentialsProvider);
    if (snapshot.rememberEnabled &&
        snapshot.hasSavedPassword &&
        !_passwordTouched) {
      _passwordController.text = snapshot.savedPassword!;
      setState(() => _remember = true);
    }
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
    final notifier = ref.read(authNotifierProvider.notifier);
    await notifier.login(
      username: username,
      password: password,
    );
    if (!mounted) return;
    final credentials = ref.read(savedCredentialsProvider.notifier);
    if (ref.read(authNotifierProvider).session != null) {
      // 勾了才存，没勾就把本机残留清掉（用户可能正是这次取消的）。
      await credentials.onLoginSucceeded(password);
      if (mounted) context.go('/overview');
      return;
    }
    // 只把「服务端明确拒绝了这组凭据」计入失败次数。
    // 断网、服务器 502、客户端未配地址都不是密码的问题：这类失败连着来三次
    // 就把本机密码删掉，等于让人在高铁上丢了自动填充。
    final credentialRejected = notifier.lastLoginFailureWasCredentialRejection;
    if (!credentialRejected) return;
    // 失败计数落在 provider 里：页面被重建也不会归零，第 3 次一定清得掉。
    final cleared = await credentials.recordFailure();
    if (cleared && mounted) setState(() => _remember = false);
  }

  /// 勾选/取消「保存密码」。
  ///
  /// 取消勾选立刻删除本机密码：用户的意图是「现在别存了」，
  /// 拖到下次登录成功才删，等于在他明确拒绝之后还留着。
  Future<void> _onRememberChanged(bool enabled) async {
    setState(() => _remember = enabled);
    await ref.read(savedCredentialsProvider.notifier).setRemember(enabled);
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
    // 改址即清密码：旧密码属于旧服务器，留着只会让自动填充把用户
    // 送进「用户名或密码错误」——而真正的错因是他刚换了地址。
    await ref.read(savedCredentialsProvider.notifier).clearForServerChange();
    if (!mounted) return;
    _passwordController.clear();
    _passwordTouched = false;
    setState(() {
      _activeBaseUrl = saved;
      _remember = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('服务器地址已更新，已清除本机保存的密码（旧密码对新服务器无效）'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final credentials = ref.watch(savedCredentialsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('登录 Fleetboard')),
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
                      onChanged: (_) => _passwordTouched = true,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    // 默认不勾：免密登录是用户主动选择的结果，不是默认便利。
                    CheckboxListTile(
                      value: _remember,
                      onChanged: auth.loading
                          ? null
                          : (v) => _onRememberChanged(v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(
                        '保存密码',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.text),
                      ),
                    ),
                    Text(
                      '密码保存在本机 Keystore，仅用于自动填充；换设备不会同步。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.muted),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (auth.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text(
                          auth.error!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.danger),
                        ),
                      ),
                    // 清掉本机密码是用户看不到的副作用，必须当场说清，
                    // 否则下次进页面「怎么不自动填了」会变成新的困惑。
                    if (credentials.clearedByFailures)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Text(
                          '已清除本机保存的密码：连续 $maxLoginFailuresBeforeClear 次登录失败，'
                          '说明本机这份密码很可能已失效，请核对后重新输入。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.warn),
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
