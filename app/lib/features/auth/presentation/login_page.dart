import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 登录页（M9.1 占位空壳）。
///
/// M9.2 落地：JWT 登录表单 + 静默续期 + 重定向。
class LoginPage extends ConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: const Center(
        child: Text('登录占位 · M9.2'),
      ),
    );
  }
}
