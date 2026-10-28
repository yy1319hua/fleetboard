import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 设置页（Tab 3，M9.1 占位空壳）。
///
/// M9.2/5 落地：设置项 + 关于页版本（B8）+ 检查更新/下载/SHA-256 校验（B9）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Center(child: Text('设置占位 · M9.2/M9.5')),
    );
  }
}
