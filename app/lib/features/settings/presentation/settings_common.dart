import 'package:flutter/material.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';

/// 设置子页共用的小件。
///
/// 只放「每页都要、且语义固定」的东西：读取失败态与轻提示。
/// 不放业务控件 —— 各页表单差异大，抽公共表单反而会增加理解成本。

/// 读取失败态：必须给出可执行的重试，不允许出现空白页。
class SettingsLoadError extends StatelessWidget {
  const SettingsLoadError({
    super.key,
    required this.message,
    required this.onRetry,
    this.title = '读取设置失败',
  });

  final String message;
  final VoidCallback onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined,
                color: AppColors.danger, size: 28),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: AppColors.faint),
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// 底部轻提示。错误用 danger 底色，成功保持默认面板色。
void showToast(
  BuildContext context,
  String text, {
  bool isError = false,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: isError ? AppColors.danger : AppColors.s2,
      duration: Duration(seconds: isError ? 4 : 2),
    ),
  );
}

/// 表单字段的统一样式：等宽字体 + 紧凑边框。
InputDecoration fieldDecoration(String hint, {String? helper}) {
  return InputDecoration(
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    border: const OutlineInputBorder(),
    isDense: true,
  );
}
