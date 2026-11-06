import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../domain/terminal_frames.dart';

/// 终端 WS 客户端（App 直连带 `Authorization: Bearer`）。
///
/// 与容器日志客户端的最大差别：**不自动重连**。
/// 日志断了重连只是接上新的 tail，用户几乎无感；而终端断在半条命令上时
/// 悄悄重连，会让用户以为还是原来那个 shell——实际上 cwd、环境变量、
/// 正在跑的进程全没了。宁可停在那儿提示「已断开」并给一个重连按钮。
class TerminalClient {
  TerminalClient({
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.cols,
    required this.rows,
    required this.onOutput,
    required this.onExit,
    required this.onClosed,
  });

  final String baseUrl;
  final String token;
  final int serverId;
  final int cols;
  final int rows;

  final void Function(Uint8List bytes) onOutput;
  final void Function(int code) onExit;
  final void Function(String reason) onClosed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  Timer? _resizeDebounce;
  int _pendingCols = 0;
  int _pendingRows = 0;
  bool _closedByUs = false;

  /// 心跳取 25s：服务端 30s 发 ping、90s 无 pong 判死。客户端自己发应用层
  /// 心跳是为了让**服务端**的读超时也持续续期——手机网络在 NAT 上被回收时，
  /// 双向都可能静默，只有双方都在说话才能尽早发现。
  static const Duration _heartbeatEvery = Duration(seconds: 25);

  /// 软键盘弹出/收起会连续触发多次尺寸变化；逐次发 resize 会让远端
  /// 每 16ms 就 SIGWINCH 一次，vim 会疯狂重绘、日志会刷满控制序列。
  static const Duration _resizeDebounceDelay = Duration(milliseconds: 150);

  Uri get _uri {
    final u = Uri.parse(baseUrl);
    return Uri(
      scheme: u.scheme == 'https' ? 'wss' : 'ws',
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/api/servers/$serverId/terminal',
      queryParameters: <String, String>{'cols': '$cols', 'rows': '$rows'},
    );
  }

  void connect() {
    _closedByUs = false;
    try {
      final ch = IOWebSocketChannel.connect(
        _uri,
        headers: <String, dynamic>{'Authorization': 'Bearer $token'},
        // 终端首帧要等远端 shell 起来才回来，握手慢一点属正常；
        // 但不设上限会让「连不上」表现为长时间白屏。
        connectTimeout: const Duration(seconds: 15),
      );
      _channel = ch;
      _sub = ch.stream.listen(
        _onRaw,
        onError: (Object e) => _finish('连接出错：$e'),
        onDone: () => _finish('连接已断开'),
        cancelOnError: true,
      );
      _heartbeat = Timer.periodic(_heartbeatEvery, (_) {
        _send(TermOut.ping());
      });
    } on Object catch (e) {
      _finish('无法建立连接：$e');
    }
  }

  void _onRaw(dynamic raw) {
    final frame = TermFrame.decode(raw);
    if (frame == null) return;
    switch (frame.type) {
      case TermFrameType.output:
        final b = frame.bytes;
        if (b != null && b.isNotEmpty) onOutput(b);
        break;
      case TermFrameType.exited:
        // 远端 shell 正常退出（exit / 被杀）。先告诉 UI，再按断开收尾。
        onExit(frame.exitCode ?? 0);
        _finish('会话已结束');
        break;
      case TermFrameType.error:
        _finish(frame.message ?? '终端异常');
        break;
      case TermFrameType.unknown:
        break;
    }
  }

  void sendInput(List<int> bytes) {
    if (bytes.isEmpty) return;
    _send(TermOut.input(bytes));
  }

  /// 合并窗口内的连续 resize，只把最后一次发给服务端。
  void requestResize(int cols, int rows) {
    _pendingCols = cols;
    _pendingRows = rows;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(_resizeDebounceDelay, () {
      if (_closedByUs) return;
      _send(TermOut.resize(cols: _pendingCols, rows: _pendingRows));
    });
  }

  void _send(String payload) {
    if (_closedByUs) return;
    try {
      _channel?.sink.add(payload);
    } on Object {
      _finish('发送失败，连接可能已断开');
    }
  }

  void _finish(String reason) {
    if (_closedByUs) return;
    _closedByUs = true;
    _heartbeat?.cancel();
    _resizeDebounce?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } on Object {
      // 已经断了，关闭失败无所谓。
    }
    onClosed(reason);
  }

  /// 用户主动关闭页面：不触发 onClosed，避免页面销毁时弹「已断开」。
  void dispose() {
    _closedByUs = true;
    _heartbeat?.cancel();
    _resizeDebounce?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } on Object {
      // 同上。
    }
  }
}
