import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 服务器详情页（二级占位空壳，M9.1 仅路由占位）。
///
/// M9.3 落地：单页 + 分段控件（概览/容器/包）；深链 `?segment=&filter=` 预置；
/// 全屏确认 + 危险操作手输容器名前 4 位（FullscreenConfirm）。
class ServerDetailPage extends ConsumerWidget {
  const ServerDetailPage({super.key, required this.serverId});
  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器详情')),
      body: Center(child: Text('服务器详情占位 · serverId=$serverId · M9.3')),
    );
  }
}
