import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../servers/application/servers_provider.dart';
import '../application/alert_rules_notifier.dart';
import '../domain/alert_rule.dart';

/// 告警规则新建 / 编辑页。
///
/// 字段严格按后端模型来，页面里没有的东西就是后端没有：
///  - 没有「规则名称」（`model.AlertRule` 无此字段，标题由指标+阈值拼出来）；
///  - 没有「持续时间」（后端没有该字段，也没有连续 N 分钟才触发的判定）；
///  - 没有「应用内通知开关」（引擎对每条命中的规则都会写通知中心，
///    只有 PushPlus 受 `notify_channels` 控制，见 `alert/engine.go`）；
///  - 指标只给 cpu/mem/disk（`offline` 虽在接口白名单里，但引擎不评估它，
///    建了永远不会触发）。
class AlertRuleEditPage extends ConsumerStatefulWidget {
  const AlertRuleEditPage({super.key, this.rule});

  /// null = 新建。
  final AlertRule? rule;

  @override
  ConsumerState<AlertRuleEditPage> createState() => _AlertRuleEditPageState();
}

class _AlertRuleEditPageState extends ConsumerState<AlertRuleEditPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _threshold = TextEditingController();

  late AlertMetric _metric;
  late String _operator;
  late String _severity;
  late bool _enabled;
  late bool _pushplus;

  /// 0 = 全局。用哨兵值而不是 null，是因为 DropdownButtonFormField 的
  /// `value: null` 会被渲染成"未选择"并显示 hint，无法表达"全局"这个真实选项。
  late int _serverScope;

  bool _saving = false;
  String? _submitError;

  bool get _isEdit => widget.rule != null;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    if (rule == null) {
      final draft = AlertRuleDraft.initial();
      _metric = AlertMetric.tryParse(draft.metric) ?? AlertMetric.cpuPct;
      _operator = draft.operator;
      _severity = draft.severity;
      _enabled = draft.enabled;
      _pushplus = draft.pushplus;
      _serverScope = 0;
      _threshold.text = formatThreshold(draft.threshold);
    } else {
      _metric = AlertMetric.tryParse(rule.metric) ?? AlertMetric.cpuPct;
      _operator = kAlertOperators.contains(rule.operator) ? rule.operator : '>';
      _severity =
          kAlertSeverities.contains(rule.severity) ? rule.severity : 'warn';
      _enabled = rule.enabled;
      _pushplus = rule.pushplusEnabled;
      _serverScope = rule.serverId ?? 0;
      _threshold.text = formatThreshold(rule.threshold);
    }
  }

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  void _submit() {
    // 先跑本地校验（就地提示），通过才发请求。
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _save();
  }

  Future<void> _save() async {
    final threshold = double.tryParse(_threshold.text.trim());
    if (threshold == null) return; // validator 已经拦过，这里只是兜底

    final draft = AlertRuleDraft(
      metric: _metric.wire,
      operator: _operator,
      threshold: threshold,
      severity: _severity,
      enabled: _enabled,
      pushplus: _pushplus,
      serverId: _serverScope == 0 ? null : _serverScope,
    );

    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final saved = await ref.read(alertRulesProvider.notifier).save(
            draft: draft,
            origin: widget.rule,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(content: Text(_isEdit ? '已保存规则 #${saved.id}' : '已新建规则 #${saved.id}')),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = describeApiError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑告警规则' : '新建告警规则')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
          children: [
            if (_isEdit)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '规则 #${widget.rule!.id}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            // 指标
            DropdownButtonFormField<AlertMetric>(
              value: _metric,
              decoration: const InputDecoration(
                labelText: '监控指标',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final metric in AlertMetric.values)
                  DropdownMenuItem<AlertMetric>(
                    value: metric,
                    child: Text(metric.label),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _metric = value);
              },
            ),
            const SizedBox(height: 4),
            Text(
              '只提供 CPU / 内存 / 磁盘三项。后端 metric 白名单里还有 offline，'
              '但告警引擎不评估它（只看数值指标），建了也不会触发，所以这里不给。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // 比较符 + 阈值
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<String>(
                    value: _operator,
                    decoration: const InputDecoration(
                      labelText: '比较',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final op in kAlertOperators)
                        DropdownMenuItem<String>(value: op, child: Text(op)),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _operator = value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _threshold,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: '阈值',
                      suffixText: '%',
                      border: OutlineInputBorder(),
                      helperText: '0–100，支持小数',
                    ),
                    validator: (raw) {
                      final text = (raw ?? '').trim();
                      if (text.isEmpty) return '请填写阈值';
                      final value = double.tryParse(text);
                      if (value == null) return '请填数字，例如 80';
                      if (value < 0 || value > 100) return '阈值需在 0–100 之间';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 级别
            DropdownButtonFormField<String>(
              value: _severity,
              decoration: const InputDecoration(
                labelText: '告警级别',
                border: OutlineInputBorder(),
                helperText: '级别只影响通知里的标记，不改变是否触发',
              ),
              items: [
                for (final severity in kAlertSeverities)
                  DropdownMenuItem<String>(
                    value: severity,
                    child: Text(alertSeverityLabel(severity)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _severity = value);
              },
            ),
            const SizedBox(height: 16),

            // 作用范围
            _ServerScopeField(
              value: _serverScope,
              // 编辑时归属不可改：后端 merge 接口收到 server_id 直接 400。
              locked: _isEdit,
              onChanged: (value) => setState(() => _serverScope = value),
            ),
            const SizedBox(height: 16),

            // 通知渠道
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('通知方式', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.notifications_active_outlined,
                          size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '应用内通知：始终开启（规则命中就会写进通知中心，关不掉）',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('同时推送 PushPlus'),
                    subtitle: const Text(
                      '需要先在设置里填好 PushPlus token，否则只会写通知中心',
                    ),
                    value: _pushplus,
                    onChanged: (value) => setState(() => _pushplus = value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用这条规则'),
              subtitle: const Text('关闭后规则保留但不再评估，可随时再打开'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),

            if (_submitError != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '保存失败：$_submitError',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_isEdit ? '保存改动' : '创建规则'),
          ),
        ),
      ),
    );
  }
}

/// 作用范围选择器：全局 或 某一台服务器。
class _ServerScopeField extends ConsumerWidget {
  const _ServerScopeField({
    required this.value,
    required this.locked,
    required this.onChanged,
  });

  final int value;
  final bool locked;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final servers = ref.watch(serversProvider);

    if (locked) {
      return InputDecorator(
        decoration: const InputDecoration(
          labelText: '作用范围',
          border: OutlineInputBorder(),
        ),
        child: Text(
          value == 0 ? '全局（所有服务器）' : '服务器 #$value',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return servers.when(
      loading: () => const InputDecorator(
        decoration: InputDecoration(
          labelText: '作用范围',
          border: OutlineInputBorder(),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('正在加载服务器列表…'),
          ],
        ),
      ),
      error: (error, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InlineErrorBar(
            message: '服务器列表加载失败：${describeApiError(error)}',
            onRetry: () => ref.invalidate(serversProvider),
          ),
          const SizedBox(height: 8),
          Text(
            '加载不到列表时不建议盲选：可以先把规则建为「全局」，'
            '再到 Web 端改归属（App 端不支持改归属）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      data: (list) {
        // 规则指向的服务器可能已被删除：DropdownButton 要求 value 必须命中某一项，
        // 否则直接抛断言。所以这里补一个"已不在纳管列表"的占位项。
        final orphan = value != 0 && !list.any((server) => server.id == value);
        return DropdownButtonFormField<int>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '作用范围',
            border: OutlineInputBorder(),
            helperText: '选「全局」对每台机器生效；规则建好后归属不可修改',
          ),
          items: [
            const DropdownMenuItem<int>(value: 0, child: Text('全局（所有服务器）')),
            if (orphan)
              DropdownMenuItem<int>(
                value: value,
                child: Text('服务器 #$value（已不在纳管列表）'),
              ),
            for (final server in list)
              DropdownMenuItem<int>(
                value: server.id,
                child: Text('${server.name}（#${server.id}）'),
              ),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        );
      },
    );
  }
}
