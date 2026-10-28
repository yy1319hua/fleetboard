import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 单条日志块（对齐 realtime-contract.yaml LogChunk）。
class LogChunk {
  const LogChunk({required this.ts, required this.stream, required this.text});

  final String ts;
  final String stream; // stdout / stderr
  final String text;

  factory LogChunk.fromJson(Map<String, dynamic> json) => LogChunk(
        ts: json['ts'] as String? ?? '',
        stream: json['stream'] as String? ?? 'stdout',
        text: json['text'] as String? ?? '',
      );
}

/// 容器日志 WS 客户端：App 直连带 `Authorization: Bearer` 绕过 logs-ticket；
/// 断线按退避 ≤[maxRetries] 次自动重连（B3）。
class LogsWsClient {
  LogsWsClient({
    required this.baseUrl,
    required this.token,
    required this.serverId,
    required this.cid,
    this.tail = 200,
    this.maxRetries = 3,
  });

  final String baseUrl;
  final String token;
  final int serverId;
  final String cid;
  final int tail;
  final int maxRetries;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _retries = 0;
  bool _closed = false;

  final StreamController<LogChunk> _controller =
      StreamController<LogChunk>.broadcast();

  Stream<LogChunk> get stream => _controller.stream;

  Uri get _wsUri {
    final u = Uri.parse(baseUrl);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/api/servers/$serverId/containers/$cid/logs',
      queryParameters: <String, String>{'tail': '$tail'},
    );
  }

  void connect() {
    _closed = false;
    _open();
  }

  void _open() {
    if (_closed) return;
    try {
      final ch = IOWebSocketChannel.connect(
        _wsUri,
        headers: <String, dynamic>{'Authorization': 'Bearer $token'},
      );
      _channel = ch;
      _sub = ch.stream.listen(
        (dynamic raw) {
          _retries = 0; // 收到数据即视为已恢复
          final chunk = _parse(raw);
          if (chunk != null && !_controller.isClosed) _controller.add(chunk);
        },
        onError: (Object _) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } on Object {
      _scheduleReconnect();
    }
  }

  LogChunk? _parse(dynamic raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return LogChunk.fromJson(decoded);
    } on Object {
      // 非 JSON 帧按原始文本处理。
      return LogChunk(ts: '', stream: 'stdout', text: raw);
    }
    return null;
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (_closed || _retries >= maxRetries) {
      if (!_controller.isClosed) _controller.close();
      return;
    }
    _retries++;
    Timer(Duration(seconds: _retries), _open); // 退避：1s / 2s / 3s
  }

  Future<void> dispose() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    if (!_controller.isClosed) await _controller.close();
  }
}
