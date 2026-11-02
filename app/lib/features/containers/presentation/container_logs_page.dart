import 'package:flutter/material.dart' hide Container;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/application/auth_notifier.dart';
import '../data/logs_ws_client.dart';
import '../domain/container.dart';

/// 容器实时日志页（M9.3 步3）：WS 直连带 Bearer，断线 ≤3 次自动重连（B3）。
///
/// v0.4.7：支持长按选中复制（`SelectionArea`）+ 一键复制全部。
/// 实时流有两个坑，这里都处理了：
/// 1. 原来每来一行就 `jumpTo(maxScrollExtent)`，用户手指一碰选择就被拽回底部，
///    根本选不中。改为「只有贴底时才自动跟随」，上滑即暂停，并给一个「回到底部」按钮。
/// 2. `_lines` 无上限增长，长时间挂着会吃内存。超过 [maxLines] 丢弃最旧的行。
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
  /// 内存里最多保留的日志行数；超出丢弃最旧的行。
  static const int maxLines = 5000;

  /// 距底部多少像素以内算「贴底」，仍在自动跟随。
  static const double _stickThreshold = 48;

  LogsWsClient? _client;
  final List<LogChunk> _lines = <LogChunk>[];
  final ScrollController _scroll = ScrollController();

  /// 是否跟随最新日志。用户往上滑或开始选择时自动置 false。
  bool _followTail = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
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
        setState(() {
          _lines.add(chunk);
          if (_lines.length > maxLines) {
            _lines.removeRange(0, _lines.length - maxLines);
          }
        });
        if (_followTail) _scrollToEnd();
      });
      client.connect();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels <
            _stickThreshold;
    if (atBottom != _followTail) setState(() => _followTail = atBottom);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _copyAll() async {
    if (_lines.isEmpty) return;
    final text = _lines.map((LogChunk c) => c.text).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_lines.length} 行日志')),
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
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
      appBar: AppBar(
        title: Text('日志 · $name'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制全部日志',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _lines.isEmpty ? null : _copyAll,
          ),
        ],
      ),
      body: _lines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: <Widget>[
                // SelectionArea 让整段日志可长按选中、跨行拖选、走系统复制菜单。
                SelectionArea(
                  child: ListView.builder(
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
                ),
                // 暂停跟随时给一个明确的「回到底部」，否则新日志在下面滚，
                // 用户不知道自己看的是不是最新。
                if (!_followTail)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      tooltip: '回到底部',
                      onPressed: () {
                        setState(() => _followTail = true);
                        _scrollToEnd();
                      },
                      child: const Icon(Icons.arrow_downward),
                    ),
                  ),
              ],
            ),
    );
  }
}
