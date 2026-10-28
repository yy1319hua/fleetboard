import 'package:flutter/material.dart';

import '../constants.dart';
import '../theme/app_theme.dart';

/// 全屏确认：危险操作（重启/删除）前，要求手输容器名前 4 位方可确认。
///
/// 通过 `Navigator.push<bool>(MaterialPageRoute(fullscreenDialog: true))` 打开，
/// 返回 true 表示确认执行。
class FullscreenConfirm extends StatefulWidget {
  const FullscreenConfirm({
    super.key,
    required this.title,
    required this.message,
    required this.expectedToken,
  });

  final String title;
  final String message;

  /// 需用户手输的期望串（容器名前 4 位，不足 4 位取实际长度）。
  final String expectedToken;

  @override
  State<FullscreenConfirm> createState() => _FullscreenConfirmState();
}

class _FullscreenConfirmState extends State<FullscreenConfirm> {
  final TextEditingController _ctrl = TextEditingController();
  bool _matches = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.danger),
                ),
                child: Text(
                  widget.message,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.danger),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                '请输入「${widget.expectedToken}」以确认（容器名前 4 位）',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '在此输入确认串',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(
                  () => _matches = v.trim() == widget.expectedToken,
                ),
              ),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  minimumSize: const Size(0, touchMin),
                ),
                onPressed:
                    _matches ? () => Navigator.of(context).pop(true) : null,
                child: const Text('确认执行'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
