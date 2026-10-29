import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../application/settings_provider.dart';
import '../data/settings_repository.dart';
import '../domain/settings.dart';
import 'settings_common.dart';

/// 通知推送设置（PushPlus）。
///
/// 关键取舍：输入框**不回填掩码**（`****1234`）。填进去用户会以为那是真值，
/// 改一个字符再保存就把 `****1234` 当令牌写进库。所以留空 = 不修改，
/// 已设置与否只体现在提示文案里。
class SettingsPushPage extends ConsumerStatefulWidget {
  const SettingsPushPage({super.key});

  @override
  ConsumerState<SettingsPushPage> createState() => _SettingsPushPageState();
}

class _SettingsPushPageState extends ConsumerState<SettingsPushPage> {
  final TextEditingController _token = TextEditingController();
  bool _saving = false;
  bool _testing = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  String get _input => _token.text.trim();

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('通知推送')),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => SettingsLoadError(
          message: describeApiError(e),
          onRetry: () => ref.invalidate(settingsProvider),
        ),
        data: _body,
      ),
    );
  }

  Widget _body(SettingsResponse data) {
    final theme = Theme.of(context);
    final entry = data.entries
        .where((SettingEntry e) => e.key == 'pushplus.token')
        .firstOrNull;
    final configured = entry?.isSet ?? false;
    final masked = entry?.displayValue ?? '（未设置）';
    final busy = _saving || _testing;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('PushPlus 令牌', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  configured ? '当前已设置：$masked' : '当前未设置，告警无法推送到微信。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: configured ? AppColors.faint : AppColors.warn,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _token,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: fieldDecoration(
                    configured ? '留空则不修改已存令牌' : '粘贴 PushPlus token',
                  ),
                  style: const TextStyle(fontFamily: 'JetBrains Mono'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '令牌加密存于服务器，回读只显示尾 4 位。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.faint),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: busy ? null : () => _runTest(configured),
                child: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('发送测试推送'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton(
                onPressed: (busy || _input.isEmpty) ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '「发送测试推送」优先用输入框里的新令牌，验证通过再保存 —— '
          '避免把错令牌存进库、告警静默失效。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
        ),
      ],
    );
  }

  Future<void> _runTest(bool configured) async {
    if (_input.isEmpty && !configured) {
      showToast(context, '请先填写令牌，或先保存一个令牌', isError: true);
      return;
    }
    setState(() => _testing = true);
    try {
      await ref.read(settingsRepositoryProvider).testChannel(token: _input);
      if (!mounted) return;
      showToast(
        context,
        _input.isEmpty ? '测试推送已发送（使用已存令牌）' : '测试推送已发送，请查看微信',
      );
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '测试失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_input.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .updateSettings(<String, String>{'pushplus.token': _input});
      ref.invalidate(settingsProvider);
      if (!mounted) return;
      _token.clear();
      showToast(context, '已保存');
    } on Object catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败：${describeApiError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
