import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../application/settings_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings.dart';
import 'settings_common.dart';

/// 采集与保留设置：采集间隔 / 指标保留天数 / 离线阈值 / Compose 根目录。
///
/// 保存策略：**只提交被改动的 key**。后端是 merge 语义，但把未改动的值一并
/// 回写仍有风险 —— 服务端可能已在别处（Web / 另一台设备）改过，回写会把它覆盖掉。
class SettingsMonitorPage extends ConsumerStatefulWidget {
  const SettingsMonitorPage({super.key});

  @override
  ConsumerState<SettingsMonitorPage> createState() =>
      _SettingsMonitorPageState();
}

class _SettingsMonitorPageState extends ConsumerState<SettingsMonitorPage> {
  final TextEditingController _interval = TextEditingController();
  final TextEditingController _retention = TextEditingController();
  final TextEditingController _threshold = TextEditingController();
  final TextEditingController _roots = TextEditingController();

  /// 原值快照：用于判断「哪些 key 真被改了」，以及「撤销修改」。
  final Map<String, String> _origin = <String, String>{};
  bool _filled = false;
  bool _saving = false;

  @override
  void dispose() {
    _interval.dispose();
    _retention.dispose();
    _threshold.dispose();
    _roots.dispose();
    super.dispose();
  }

  void _fillOnce(SettingsResponse data) {
    if (_filled) return;
    _filled = true;
    String raw(String key) {
      final e =
          data.entries.where((SettingEntry x) => x.key == key).firstOrNull;
      return e?.displayValue ?? '';
    }

    _origin['monitor.interval'] = raw('monitor.interval');
    _origin['metrics.retention_days'] = raw('metrics.retention_days');
    _origin['monitor.offline_threshold'] = raw('monitor.offline_threshold');
    _origin['compose.roots'] = raw('compose.roots');

    _interval.text = _origin['monitor.interval']!;
    _retention.text = _origin['metrics.retention_days']!;
    _threshold.text = _origin['monitor.offline_threshold']!;
    _roots.text = _origin['compose.roots']!
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .join('\n');
  }

  String get _rootsAsCsv => _roots.text
      .split(RegExp(r'[\n,]'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .join(',');

  /// 收集改动项；返回 null 表示校验未过（已提示用户）。
  Map<String, String>? _collectChanges() {
    final changes = <String, String>{};

    void maybePut(String key, String current) {
      if (current != (_origin[key] ?? '')) changes[key] = current;
    }

    maybePut('monitor.interval', _interval.text.trim());
    maybePut('metrics.retention_days', _retention.text.trim());
    maybePut('monitor.offline_threshold', _threshold.text.trim());
    maybePut('compose.roots', _rootsAsCsv);

    // 校验：整数范围与路径绝对性。空值不提交（等于不修改），避免把设置清空。
    for (final entry in <String, (int, int, String)>{
      'monitor.interval': (1, 3600, '采集间隔'),
      'metrics.retention_days': (1, 3650, '保留天数'),
      'monitor.offline_threshold': (1, 100, '离线阈值'),
    }.entries) {
      if (!changes.containsKey(entry.key)) continue;
      final v = int.tryParse(changes[entry.key]!);
      if (v == null) {
        showToast(context, '${entry.value.$3}必须是整数', isError: true);
        return null;
      }
      if (v < entry.value.$1 || v > entry.value.$2) {
        showToast(
          context,
          '${entry.value.$3}需在 ${entry.value.$1}–${entry.value.$2} 之间',
          isError: true,
        );
        return null;
      }
    }
    if (changes.containsKey('compose.roots')) {
      final bad = _rootsAsCsv
          .split(',')
          .where((String s) => s.isNotEmpty && !s.startsWith('/'))
          .toList();
      if (bad.isNotEmpty) {
        showToast(context, 'Compose 根目录必须是绝对路径：${bad.first}', isError: true);
        return null;
      }
    }
    return changes;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('采集与保留')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => SettingsLoadError(
          message: describeApiError(e),
          onRetry: () => ref.invalidate(settingsProvider),
        ),
        data: (SettingsResponse data) {
          _fillOnce(data);
          return _body();
        },
      ),
    );
  }

  Widget _body() {
    final theme = Theme.of(context);
    final dirty = _collectChangesQuietly().isNotEmpty;

    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('监控采集', style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.md),
                      _NumberField(
                        controller: _interval,
                        label: '采集间隔（秒）',
                        hint: '默认 30',
                        onChanged: _refresh,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _NumberField(
                        controller: _retention,
                        label: '指标保留天数',
                        hint: '默认 30',
                        onChanged: _refresh,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _NumberField(
                        controller: _threshold,
                        label: '离线判定阈值（连续失败次数）',
                        hint: '默认 2',
                        onChanged: _refresh,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '采集间隔越小曲线越细，磁盘与 SSH 负载也越高；'
                        '保留天数决定 7 天曲线能否看全。',
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
                      Text('Compose 根目录', style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '每行一个绝对路径，决定 Compose 页能浏览哪些目录。留空表示不限制扫描根。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.faint),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextField(
                        controller: _roots,
                        minLines: 3,
                        maxLines: 6,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration:
                            fieldDecoration('/opt/stacks\n/home/me/docker'),
                        style: const TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 13,
                        ),
                        onChanged: (_) => _refresh(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _SaveBar(
          dirty: dirty,
          saving: _saving,
          onSave: _save,
          onReset: _reset,
        ),
      ],
    );
  }

  Map<String, String> _collectChangesQuietly() {
    final changes = <String, String>{};
    void maybePut(String key, String current) {
      if (current != (_origin[key] ?? '')) changes[key] = current;
    }

    maybePut('monitor.interval', _interval.text.trim());
    maybePut('metrics.retention_days', _retention.text.trim());
    maybePut('monitor.offline_threshold', _threshold.text.trim());
    maybePut('compose.roots', _rootsAsCsv);
    return changes;
  }

  void _refresh() => setState(() {});

  void _reset() {
    _interval.text = _origin['monitor.interval'] ?? '';
    _retention.text = _origin['metrics.retention_days'] ?? '';
    _threshold.text = _origin['monitor.offline_threshold'] ?? '';
    _roots.text = (_origin['compose.roots'] ?? '')
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .join('\n');
    setState(() {});
  }

  Future<void> _save() async {
    final changes = _collectChanges();
    if (changes == null || changes.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).updateSettings(changes);
      // 保存成功后把新值当基准，避免「保存了还提示有未保存改动」。
      _origin.addAll(changes);
      ref.invalidate(settingsProvider);
      if (!mounted) return;
      showToast(context, '已保存 ${changes.length} 项');
      setState(() {});
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: fieldDecoration(hint),
          style: const TextStyle(fontFamily: 'JetBrains Mono'),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}

/// 底部保存条：常驻可见，未改动时置灰而不是隐藏（隐藏会让用户以为没有保存入口）。
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.dirty,
    required this.saving,
    required this.onSave,
    required this.onReset,
  });

  final bool dirty;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
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
            Expanded(
              child: OutlinedButton(
                onPressed: dirty && !saving ? onReset : null,
                child: const Text('撤销'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: dirty && !saving ? onSave : null,
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(dirty ? '保存改动' : '没有改动'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
