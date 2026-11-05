import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../overview/domain/bootstrap.dart';
import '../../settings/presentation/settings_common.dart';
import '../data/servers_repository.dart';
import '../domain/private_key_validator.dart';

/// 服务器向导：新增与编辑共用（三步）。
///
/// **先测后存**：点「测试并保存」时先调 `POST /api/servers/probe` 试连，
/// 探通才落库（新增走 POST，编辑走 PUT）。探不通就停在原地显示原因，
/// 列表里什么都不会多——不会出现一台永远连不上、还被监控循环反复告警的机器。
///
/// 编辑模式（传入 [server]）：元信息预填；凭据默认「已保存，留空则不修改」，
/// 只有打开「更换凭据」或切换认证方式时才要求重新填写。
class ServerWizardPage extends ConsumerStatefulWidget {
  const ServerWizardPage({super.key, this.server});

  /// 非空 = 编辑该服务器；空 = 新增。
  final Server? server;

  bool get isEdit => server != null;

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

  /// 编辑模式下是否更换凭据；新增模式恒为 true（必须提供）。
  bool _replaceCredential = true;

  bool _submitting = false;
  String? _failure;
  bool _done = false;

  /// 编辑且未更换凭据、也未切换认证方式时，凭据沿用库中原值。
  bool get _needCredential {
    final s = widget.server;
    if (s == null) return true;
    if (_replaceCredential) return true;
    return _authMethod != s.authMethod;
  }

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    if (s != null) {
      _name.text = s.name;
      _host.text = s.host;
      _port.text = '${s.port}';
      _user.text = s.sshUser;
      _authMethod = s.authMethod;
      _replaceCredential = false;
    }
  }

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
          title: Text(widget.isEdit ? '编辑服务器' : '新增服务器'),
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
                    : Text(_step == 2 ? '测试并保存' : '下一步'),
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
          decoration: fieldDecoration('主机名或 IP', helper: '例：192.168.1.10'),
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
            setState(() {
              _authMethod = v.first;
              // 编辑时切换认证方式：原凭据必然不可复用，直接打开「更换凭据」。
              final s = widget.server;
              if (s != null && _authMethod != s.authMethod) {
                _replaceCredential = true;
              }
            });
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

    // 编辑且沿用原凭据：不必重填，给一个明确的只读态。
    if (!_needCredential) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline, size: 20),
              title: const Text('凭据已保存'),
              subtitle: Text(
                '留空则保持不变。改名称、地址、端口或标签都不必重填凭据。',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: () => setState(() => _replaceCredential = true),
            icon: const Icon(Icons.key_outlined, size: 18),
            label: const Text('更换凭据'),
          ),
        ],
      );
    }

    final editing = widget.isEdit;
    if (_authMethod == 'password') {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          if (editing) ...<Widget>[
            _ReplaceHint(onCancel: _cancelReplace),
            const SizedBox(height: AppSpacing.md),
          ],
          Text(
            editing
                ? '留空则沿用原密码；填写则替换。密码会加密存放在面板服务器上。'
                : '密码只用于 SSH 登录，会加密存放在面板服务器上。',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: fieldDecoration(
              'SSH 登录密码',
              helper: editing ? '留空 = 不修改' : null,
            ),
          ),
        ],
      );
    }

    final check = _keyCheck;
    final blocker = check?.firstBlocker;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        if (editing) ...<Widget>[
          _ReplaceHint(onCancel: _cancelReplace),
          const SizedBox(height: AppSpacing.md),
        ],
        Text(
          editing ? '留空则沿用原私钥；粘贴新私钥则替换。' : '粘贴 OpenSSH 私钥全文',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '私钥须含 BEGIN / END 头尾两行。粘贴后会自动检查格式，'
          '不用等到测试连接才发现粘错。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _pasteFromClipboard,
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('从剪贴板粘贴'),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: _key,
          minLines: 6,
          maxLines: 12,
          autocorrect: false,
          enableSuggestions: false,
          decoration: fieldDecoration('（BEGIN 行）…（END 行）'),
          style: const TextStyle(
              fontFamily: 'JetBrains Mono', fontSize: AppFontSizes.caption),
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

  void _cancelReplace() {
    setState(() {
      _replaceCredential = false;
      _password.clear();
      _key.clear();
      _keyPass.clear();
      _keyCheck = null;
    });
  }

  // ---------- 第 3 步：提交与结果 ----------

  Widget _submitStep() {
    final theme = Theme.of(context);
    if (_done) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          const SizedBox(height: AppSpacing.xl),
          const Icon(
            Icons.check_circle_outline,
            size: 40,
            color: AppColors.ok,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            widget.isEdit ? '已保存，连接正常' : '已连接，已纳入总览',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            widget.isEdit ? '新配置已生效，可以查看指标与容器。' : '服务器已加入总览，可以查看指标与容器。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
          ),
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
        if (_failure != null) ...<Widget>[
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.warn),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.error_outline,
                        size: 16, color: AppColors.warn),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        widget.isEdit ? '未保存：新配置连接失败' : '未添加：连接失败',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '$_failure',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.muted),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '服务器没有被加入总览，改好后再点一次「测试并保存」。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.faint),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
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
                if (widget.isEdit)
                  _ReviewRow(
                    label: '凭据',
                    value: _needCredential ? '将替换为新填写的凭据' : '保持不变',
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '点击「测试并保存」后：先发起一次 SSH 连接验证，通过了才写入面板。'
          '连不上就停在当前页并给出原因，不会留下一条连不上的记录。',
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

  /// 该认证方式的凭据是否必填。
  ///
  /// 新增必填；编辑时只有「换了认证方式」才必填 —— 同一方式下留空表示沿用原值。
  bool get _credentialRequired {
    final s = widget.server;
    if (s == null) return true;
    return _authMethod != s.authMethod;
  }

  bool _validateCredential() {
    if (!_needCredential) return true;
    final required = _credentialRequired;

    if (_authMethod == 'password') {
      if (_password.text.isEmpty && required) {
        showToast(context, '请填写 SSH 登录密码', isError: true);
        return false;
      }
      return true;
    }
    final raw = _key.text;
    if (raw.trim().isEmpty) {
      if (!required) return true; // 编辑且沿用原私钥
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
    final port = int.parse(_port.text.trim());
    final name = _name.text.trim();
    final host = _host.text.trim();
    final user = _user.text.trim();

    // 未更换凭据时一律传 null（后端按「留空」处理，沿用库中原值）。
    String? password;
    String? privateKey;
    String? keyPass;
    if (_needCredential) {
      if (_authMethod == 'password') {
        if (_password.text.isNotEmpty) password = _password.text;
      } else {
        final raw = _key.text.trim();
        if (raw.isNotEmpty) privateKey = _validator.check(raw).normalized;
        if (_keyPass.text.isNotEmpty) keyPass = _keyPass.text;
      }
    }

    final editing = widget.server;
    try {
      // 第一关：先试连，不落库。探不通就在这里停住，列表里不会多出任何东西。
      await repo.probe(
        host: host,
        port: port,
        sshUser: user,
        authMethod: _authMethod,
        password: password,
        privateKey: privateKey,
        keyPass: keyPass,
        serverId: editing?.id,
      );

      // 第二关：探通了才写库。
      if (editing == null) {
        await repo.create(
          name: name,
          host: host,
          port: port,
          sshUser: user,
          authMethod: _authMethod,
          password: password,
          privateKey: privateKey,
          keyPass: keyPass,
        );
      } else {
        await repo.update(
          editing.id,
          name: name,
          host: host,
          port: port,
          sshUser: user,
          authMethod: _authMethod,
          password: password,
          privateKey: privateKey,
          keyPass: keyPass,
          // 向导没有标签输入，编辑时原样保留，避免顺手把已有标签清掉。
          tags: editing.tags,
        );
      }

      if (!mounted) return;
      setState(() => _done = true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _failure = describeApiError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

/// 编辑模式「正在更换凭据」的提示条，带一个取消入口。
class _ReplaceHint extends StatelessWidget {
  const _ReplaceHint({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '正在更换凭据',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ),
        TextButton(
          onPressed: onCancel,
          child: const Text('取消更换'),
        ),
      ],
    );
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
