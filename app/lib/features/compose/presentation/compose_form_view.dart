import 'package:flutter/material.dart';

import '../domain/compose_document.dart';

/// 按服务列出的表单编辑区。
///
/// 设计约束（都不是风格问题，是正确性问题）：
///  1. 每个字段的输入框**不随上层 rebuild 重置**：上层每次按键都会重建，
///     如果在这里用 `widget.services` 的文本回填 controller，光标会跳回开头，
///     中文输入法还会把候选词打断。所以文本以 controller 为唯一真源，
///     只在「外部整份替换」（[revision] 变化）时重建。
///  2. 写入失败要**回填**上一次成功的值：否则界面显示的文本与文件里的内容不一致，
///     用户会以为改成功了（这类"看起来保存了"的错觉在配置文件编辑里代价极大）。
///  3. 结构复杂到无法安全回写的字段不给输入框，直接说明原因并给「原文编辑」入口。
class ComposeFormView extends StatefulWidget {
  const ComposeFormView({
    super.key,
    required this.services,
    required this.revision,
    required this.onEdit,
    required this.onRequestSourceEdit,
    this.parseError,
  });

  final List<ComposeService> services;

  /// 外部整份替换的版本号；变化时重建所有 input（见类注释 1）。
  final int revision;

  /// 提交一处字段改动。可能抛 [ComposeEditException]（锚点、路径无法定位等）。
  final void Function(ServiceEdit edit) onEdit;

  final VoidCallback onRequestSourceEdit;

  /// 草稿不是合法 YAML 时的原因（用户可能在原文里刚敲坏了一个缩进）。
  final String? parseError;

  @override
  State<ComposeFormView> createState() => _ComposeFormViewState();
}

class _ComposeFormViewState extends State<ComposeFormView> {
  final Map<String, Map<ComposeFieldKey, TextEditingController>> _controllers = {};

  /// 上一次**成功写进草稿**的文本，用于失败回填与"没变就不提交"判断。
  final Map<String, Map<ComposeFieldKey, String>> _applied = {};

  @override
  void initState() {
    super.initState();
    _buildControllers();
  }

  @override
  void dispose() {
    for (final perService in _controllers.values) {
      for (final controller in perService.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  void _buildControllers() {
    for (final service in widget.services) {
      final perField = <ComposeFieldKey, TextEditingController>{};
      final appliedField = <ComposeFieldKey, String>{};
      for (final key in ComposeFieldKey.values) {
        final field = service[key];
        final controller = TextEditingController(text: field.text);
        controller.addListener(() => _onChanged(service.name, key, controller));
        perField[key] = controller;
        appliedField[key] = field.text;
      }
      _controllers[service.name] = perField;
      _applied[service.name] = appliedField;
    }
  }

  void _onChanged(
    String serviceName,
    ComposeFieldKey key,
    TextEditingController controller,
  ) {
    final text = controller.text;
    // 选区变化也会触发 listener；文本没动就直接返回，否则会把每次点光标都当成改动。
    if (_applied[serviceName]?[key] == text) return;

    try {
      widget.onEdit(_editFor(serviceName, key, text));
      _applied[serviceName]![key] = text;
    } on ComposeEditException catch (e) {
      final restored = _applied[serviceName]?[key] ?? '';
      controller.value = TextEditingValue(
        text: restored,
        selection: TextSelection.collapsed(offset: restored.length),
      );
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('这个字段改不了：${e.message}')),
      );
    }
  }

  static ServiceEdit _editFor(
    String serviceName,
    ComposeFieldKey key,
    String text,
  ) {
    return switch (key) {
      ComposeFieldKey.image => ServiceEdit(serviceName: serviceName, image: text),
      ComposeFieldKey.restart =>
        ServiceEdit(serviceName: serviceName, restart: text),
      ComposeFieldKey.command =>
        ServiceEdit(serviceName: serviceName, command: text),
      ComposeFieldKey.ports => ServiceEdit(
          serviceName: serviceName,
          ports: text.split('\n'),
        ),
      ComposeFieldKey.volumes => ServiceEdit(
          serviceName: serviceName,
          volumes: text.split('\n'),
        ),
      ComposeFieldKey.environment => ServiceEdit(
          serviceName: serviceName,
          environment: text.split('\n'),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.services.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.tune, size: 36, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              widget.parseError ?? 'services: 下没有服务，表单没有可改的字段。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: widget.onRequestSourceEdit,
              icon: const Icon(Icons.code, size: 18),
              label: const Text('切到原文编辑'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (widget.parseError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前文本不是合法 YAML，表单已停用：${widget.parseError}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final service in widget.services)
          _ServiceSection(
            service: service,
            // 单服务文件默认展开：省掉「进来先点一下」这一跳。
            initiallyExpanded: widget.services.length == 1,
            controllers: _controllers[service.name] ?? const {},
            onRequestSourceEdit: widget.onRequestSourceEdit,
          ),
      ],
    );
  }
}

class _ServiceSection extends StatelessWidget {
  const _ServiceSection({
    required this.service,
    required this.initiallyExpanded,
    required this.controllers,
    required this.onRequestSourceEdit,
  });

  final ComposeService service;
  final bool initiallyExpanded;
  final Map<ComposeFieldKey, TextEditingController> controllers;
  final VoidCallback onRequestSourceEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = service[ComposeFieldKey.image].text.trim();
    return ExpansionTile(
      // key 绑服务名：不同服务的展开状态互不影响。
      key: PageStorageKey<String>('compose-service-${service.name}'),
      initiallyExpanded: initiallyExpanded,
      title: Text(
        service.name,
        style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
      ),
      subtitle: image.isEmpty
          ? null
          : Text(
              image,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      children: [
        for (final key in ComposeFieldKey.values)
          _FieldTile(
            fieldKey: key,
            field: service[key],
            controller: controllers[key],
            onRequestSourceEdit: onRequestSourceEdit,
          ),
      ],
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.fieldKey,
    required this.field,
    required this.controller,
    required this.onRequestSourceEdit,
  });

  final ComposeFieldKey fieldKey;
  final ComposeField field;
  final TextEditingController? controller;
  final VoidCallback onRequestSourceEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!field.editable || controller == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fieldKey.label,
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Text(
                field.blockedReason ?? '该字段需在原文中编辑（表单不处理锚点与合并键）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onRequestSourceEdit,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('用「原文」编辑这个字段'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final multiLine = fieldKey.isMultiLine;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: controller,
        maxLines: multiLine ? 6 : 1,
        minLines: multiLine ? 2 : 1,
        keyboardType: multiLine ? TextInputType.multiline : TextInputType.text,
        // YAML 值里出现 `-` 被智能替换成 `–`、或首字母被自动大写，都会让配置失效。
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          labelText: fieldKey.label,
          hintText: fieldKey.hint,
          helperText: field.shapeNote,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
