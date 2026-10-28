import 'package:flutter/material.dart' hide Container;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../data/logs_ws_client.dart';
import '../domain/container.dart';

/// 容器实时日志页（M9.3 步3）：WS 直连带 Bearer，断线 ≤3 次自动重连（B3）。
class ContainerLogsPage extends ConsumerStatefulWidget {
  const ContainerLogsPage({
    super.key,
    required this.serverId,
    required this.container,
  });

  final int serverId;
  final Container container;

  @override
  ConsumerState<ContainerLogsPage> createState() => _ContainerLogsPageState();
}

class _ContainerLogsPageState extends ConsumerState<ContainerLogsPage> {
  LogsWsClient? _client;
  final List<LogChunk> _lines = <LogChunk>[];
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final session = ref.read(authNotifierProvider).session;
    if (session != null) {
      final client = LogsWsClient(
        baseUrl: session.baseUrl,
        token: session.accessToken,
        serverId: widget.serverId,
        cid: widget.container.id,
      );
      _client = client;
      client.stream.listen((chunk) {
        if (!mounted) return;
        setState(() => _lines.add(chunk));
        _scrollToEnd();
      });
      client.connect();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _client?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.container.name.isEmpty
        ? widget.container.id
        : widget.container.name;
    return Scaffold(
      appBar: AppBar(title: Text('日志 · $name')),
      body: _lines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(AppSpacing.sm),
              itemCount: _lines.length,
              itemBuilder: (context, i) {
                final c = _lines[i];
                return Text(
                  c.text,
                  style: TextStyle(
                    fontFamily: AppFonts.mono,
                    fontSize: 12,
                    height: 1.4,
                    color: c.stream == 'stderr'
                        ? AppColors.warn
                        : AppColors.text,
                  ),
                );
              },
            ),
    );
  }
}
