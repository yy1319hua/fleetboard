import 'dart:convert';
import 'dart:typed_data';

/// 终端 WS 帧（对齐 `api/realtime-contract.yaml` 的 TermFrame）。
///
/// 载荷一律 base64：PTY 输出是任意字节流，一帧可能正好切在 UTF-8 多字节
/// 字符中间。若按字符串传，那一帧就不是合法 UTF-8，解码只能塞 U+FFFD，
/// 表现为中文变「�」且只在输出量大时复现——这类问题上线后极难定位，
/// 所以在协议层就用字节表达，解码责任留给一个带状态的流式解码器。
enum TermFrameType { output, exited, error, unknown }

class TermFrame {
  const TermFrame({
    required this.type,
    this.bytes,
    this.exitCode,
    this.message,
  });

  final TermFrameType type;
  final Uint8List? bytes;
  final int? exitCode;
  final String? message;

  static TermFrame? decode(Object? raw) {
    if (raw is! String) return null;
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, dynamic>) return null;

    switch (parsed['t']) {
      case 'o':
        final d = parsed['d'];
        if (d is! String) return const TermFrame(type: TermFrameType.unknown);
        // 服务端用标准 base64；容错处理缺失填充，避免一帧解码失败就断流。
        try {
          return TermFrame(
            type: TermFrameType.output,
            bytes: base64Decode(base64.normalize(d)),
          );
        } on FormatException {
          return const TermFrame(type: TermFrameType.unknown);
        }
      case 'x':
        return TermFrame(
          type: TermFrameType.exited,
          exitCode: parsed['code'] is int ? parsed['code'] as int : -1,
        );
      case 'e':
        return TermFrame(
          type: TermFrameType.error,
          message: parsed['m'] as String? ?? '终端异常',
        );
      default:
        return const TermFrame(type: TermFrameType.unknown);
    }
  }
}

/// 出站帧的编码。分成三个具名函数而不是一个万能 builder，
/// 是因为这三种帧的字段完全不同，合并只会让调用方猜字段名。
class TermOut {
  static String input(List<int> bytes) =>
      jsonEncode(<String, Object>{'t': 'i', 'd': base64Encode(bytes)});

  static String resize({required int cols, required int rows}) =>
      jsonEncode(<String, Object>{'t': 'r', 'c': cols, 'r': rows});

  static String ping() => jsonEncode(<String, Object>{'t': 'p'});
}
