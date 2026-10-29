import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/presentation/settings_common.dart';
import '../data/servers_repository.dart';
import '../domain/private_key_validator.dart';

/// 新增服务器向导（三步）。
///
/// 顺序被后端契约锁死：`POST /api/servers/{id}/test` 要求服务器**已存在**，
/// 所以「测试连接」只能发生在创建之后。向导因此把「测试」放在第三步 —— 提交后
/// 立刻自动测一次，把结果直接摆给用户，而不是让他再去列表里找「测试连接」。
///
/// 测试失败**不回滚**：服务器记录已经建好，失败原因可能是目标机暂时不可达，
/// 回滚会让用户白填一遍。UI 明确告知「已保存但连不上」，并给出下一步。
class ServerWizardPage extends ConsumerStatefulWidget {
  const ServerWizardPage({super.key});

  @override
  ConsumerState<ServerWizardPage> createState() => _ServerWizardPageState();
}

class _ServerWizardPageState extends ConsumerState<ServerWizardPage> {
  static const PrivateKeyValidator _validator = PrivateKeyValidator();

  final PageController _pager = PageController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController(text: '22');
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _keyPass = TextEditingController();

  int _step = 0;
  String _authMethod = 'key';
  KeyCheckResult? _keyCheck;

  bool _submitting = false;
  String? _failure;
  bool _done = false;

  @override
  void dispose() {
    _pager.dispose();
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _key.dispose();
    _keyPass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('新增服务器'),
          leading: _step == 0
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '上一步',
                  onPressed: _submitting ? null : _prev,
                ),
        ),
        body: Column(
          children: <Widget>[
            _StepBar(step: _step, done: _done),
            Expanded(
              child: PageView(
                controller: _pager,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  _basicStep(),
                  _credentialStep(),
                  _submitStep(),
                ],
              ),
            ),
            if (!_done) _footer(),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        color: AppColors.s1,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: <Widget>[
            if (_step > 0)
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : _prev,
                  child: const Text('上一步'),
                ),
              ),
            if (_step > 0) const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _submitting ? null : (_step == 2 ? _submit : _next),
                child: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_step == 2 ? '保存并测试连接' : '下一步'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 第 1 步：基本信息 ----------

  Widget _basicStep() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Text(
          '先填连接目标，凭据在下一步。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _name,
          decoration: fieldDecoration('显示名称', helper: '例：amd1、家里的 NAS'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _host,
          decoration: fieldDecoration('主机名或 IP', helper: '例：10.0.0.170'),
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontFamily: 'JetBrains Mono'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _user,
                decoration: fieldDecoration('SSH 用户名', helper: '例：root、ai'),
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'JetBrains Mono'),
                textInputAction: TextInputAction.next,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _port,
                decoration: fieldDecoration('端口'),
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                style: const TextStyle(fontFamily: 'JetBrains Mono'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('认证方式', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'key',
              label: Text('SSH 私钥'),
              icon: Icon(Icons.key_outlined, size: 18),
            ),
            ButtonSegment<String>(
              value: 'password',
              label: Text('密码'),
              icon: Icon(Icons.password_outlined, size: 18),
            ),
          ],
          selected: <String>{_authMethod},
          onSelectionChanged: (Set<String> v) {
            setState(() => _authMethod = v.first);
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '私钥更安全，推荐；密码方式仅在你没有可用私钥时使用。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
      ],
    );
  }

  // ---------- 第 2 步：凭据 ----------

  Widget _credentialStep() {
    final theme = Theme.of(context);
    if (_authMethod == 'password') {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Text(
            '密码只用于 SSH 登录，会加密存放在面板服务器上。',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: fieldDecoration('SSH 登录密码'),
          ),
        ],
      );
    }

    final check = _keyCheck;
    final blocker = check?.firstBlocker;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '粘贴 OpenSSH 私钥全文',
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: _pasteFromClipboard,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('从剪贴板粘贴'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '私钥须含 BEGIN / END 头尾两行。粘贴后会自动检查格式，'
          '不用等到测试连接才发现粘错。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _key,
          minLines: 6,
          maxLines: 12,
          autocorrect: false,
          enableSuggestions: false,
          decoration: fieldDecoration('（BEGIN 行）…（END 行）'),
          style: const TextStyle(fontFamily: 'JetBrains Mono', fontSize: 12),
          onChanged: _recheck,
        ),
        if (check != null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          _KeyFeedback(result: check, onRepair: _repairKey),
        ],
        if (blocker == null) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _keyPass,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: fieldDecoration(
              '私钥口令（没有就留空）',
              helper: '带口令的私钥必须先在这里填写，否则 SSH 会认证失败',
            ),
          ),
        ],
      ],
    );
  }

  // ---------- 第 3 步：提交与结果 ----------

  Widget _submitStep() {
    final theme = Theme.of(context);
    if (_done) {
      final ok = _failure == null;
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const SizedBox(height: AppSpacing.xl),
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 40,
            color: ok ? AppColors.ok : AppColors.warn,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            ok ? '已保存并连接成功' : '已保存，但连接失败',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            ok ? '服务器已加入总览，可以查看指标与容器。' : '记录已写入面板，可以在列表里看到它。失败原因：$_failure',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
          ),
          if (!ok) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('下一步', style: theme.textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '· 确认目标机 SSH 端口可达、用户有登录权限\n'
                      '· 私钥方式：确认粘贴的是私钥全文，且口令填写正确\n'
                      '· 改完凭据需删除后重新添加（本期不支持在 App 内改凭据）',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.muted, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('完成'),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Text('确认信息', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: <Widget>[
                _ReviewRow(label: '名称', value: _name.text.trim()),
                _ReviewRow(
                  label: '地址',
                  value: '${_user.text.trim()}@${_host.text.trim()}:'
                      '${_port.text.trim()}',
                  mono: true,
                ),
                _ReviewRow(
                  label: '认证',
                  value: _authMethod == 'key' ? 'SSH 私钥' : '密码',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '点击「保存并测试连接」后：先在面板登记这台服务器，再立即发起一次 SSH 连接验证。'
          '目标机暂时不可达时记录仍会保留，不会丢你填过的内容。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.faint, height: 1.6),
        ),
      ],
    );
  }

  // ---------- 行为 ----------

  void _next() {
    if (_step == 0 && !_validateBasic()) return;
    if (_step == 1 && !_validateCredential()) return;
    _goTo(_step + 1);
  }

  void _prev() => _goTo(_step - 1);

  void _goTo(int step) {
    setState(() => _step = step);
    _pager.animateToPage(
      step,
      duration: AppMotion.medium,
      curve: AppMotion.easing,
    );
  }

  bool _validateBasic() {
    if (_name.text.trim().isEmpty) {
      showToast(context, '请填写显示名称', isError: true);
      return false;
    }
    if (_host.text.trim().isEmpty) {
      showToast(context, '请填写主机名或 IP', isError: true);
      return false;
    }
    if (_host.text.contains(' ') || _host.text.contains('/')) {
      showToast(context, '主机名不能包含空格或斜杠（不要带 https://）', isError: true);
      return false;
    }
    if (_user.text.trim().isEmpty) {
      showToast(context, '请填写 SSH 用户名', isError: true);
      return false;
    }
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      showToast(context, '端口需在 1–65535 之间', isError: true);
      return false;
    }
    return true;
  }

  bool _validateCredential() {
    if (_authMethod == 'password') {
      if (_password.text.isEmpty) {
        showToast(context, '请填写 SSH 登录密码', isError: true);
        return false;
      }
      return true;
    }
    final raw = _key.text;
    if (raw.trim().isEmpty) {
      showToast(context, '请粘贴私钥，或改用密码认证', isError: true);
      return false;
    }
    final result = _validator.check(raw);
    setState(() => _keyCheck = result);
    final blocker = result.firstBlocker;
    if (blocker != null) {
      showToast(context, blocker.message, isError: true);
      return false;
    }
    return true;
  }

  void _recheck(String raw) {
    if (raw.trim().isEmpty) {
      setState(() => _keyCheck = null);
      return;
    }
    setState(() => _keyCheck = _validator.check(raw));
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (!mounted) return;
      showToast(context, '剪贴板里没有文本', isError: true);
      return;
    }
    _key.text = text;
    _recheck(text);
    if (!mounted) return;
    final result = _keyCheck;
    if (result != null && result.hasBlocker) {
      showToast(context, '已粘贴，但格式有问题，见下方提示', isError: true);
    } else {
      showToast(context, '已粘贴，格式检查通过');
    }
  }

  void _repairKey() {
    final repaired = PrivateKeyValidator.repair(_key.text);
    _key.text = repaired;
    _recheck(repaired);
    showToast(context, '已清理不可见字符与多余空白');
  }

  Future<void> _submit() async {
    if (!_validateBasic() || !_validateCredential()) return;
    setState(() {
      _submitting = true;
      _failure = null;
    });

    final repo = ref.read(serversRepositoryProvider);
    try {
      final created = await repo.create(
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        sshUser: _user.text.trim(),
        authMethod: _authMethod,
        password: _authMethod == 'password' ? _password.text : null,
        privateKey: _authMethod == 'key'
            ? _validator.check(_key.text).normalized
            : null,
        keyPass: _authMethod == 'key' ? _keyPass.text : null,
      );

      String? testError;
      try {
        await repo.test(created.id);
      } on Object catch (e) {
        testError = describeApiError(e);
      }
      if (!mounted) return;
      setState(() {
        _done = true;
        _failure = testError;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _failure = describeApiError(e));
      showToast(context, '保存失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.done});

  final int step;
  final bool done;

  static const List<String> _labels = <String>['基本信息', '凭据', '确认'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < _labels.length; i++) ...<Widget>[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  color:
                      (step >= i || done) ? AppColors.accent : AppColors.border,
                ),
              ),
            Column(
              children: <Widget>[
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (step >= i || done)
                        ? AppColors.accentSoft
                        : Colors.transparent,
                    border: Border.all(
                      color: (step >= i || done)
                          ? AppColors.accent
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: (step >= i || done)
                          ? AppColors.accent
                          : AppColors.faint,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _labels[i],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        (step >= i || done) ? AppColors.muted : AppColors.faint,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _KeyFeedback extends StatelessWidget {
  const _KeyFeedback({required this.result, required this.onRepair});

  final KeyCheckResult result;
  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocker = result.firstBlocker;
    final ok = blocker == null;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: ok ? AppColors.s2 : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: ok ? AppColors.border : AppColors.warn,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                size: 16,
                color: ok ? AppColors.ok : AppColors.warn,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  ok ? '格式检查通过' : (blocker.message),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ok ? AppColors.muted : AppColors.text,
                  ),
                ),
              ),
            ],
          ),
          if (!ok && result.hasFixable) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onRepair,
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: const Text('一键清理不可见字符'),
              ),
            ),
          ],
          // 非阻断的提醒（例如行尾差异）也要让用户看到，否则「通过了」之后仍会失败。
          ...result.issues
              .where((KeyIssue i) => i.severity == KeyIssueSeverity.warning)
              .map(
                (KeyIssue i) => Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    '· ${i.message}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.faint),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: mono ? 'JetBrains Mono' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
