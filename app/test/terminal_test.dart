import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/terminal/domain/terminal_frames.dart';
import 'package:app/features/terminal/presentation/widgets/terminal_key_bar.dart';

void main() {
  group('TermFrame 解码', () {
    test('输出帧还原成原始字节（非 UTF-8 字节不被改写）', () {
      // 0xff 不是合法 UTF-8 起始字节。若协议按字符串传，这个字节在
      // json 编码阶段就会丢失或被替换；按 base64 传则原样到达。
      final raw = Uint8List.fromList(<int>[0x1b, 0x5b, 0x33, 0x31, 0x6d, 0xff]);
      final frame = TermFrame.decode(
        jsonEncode(<String, String>{'t': 'o', 'd': base64Encode(raw)}),
      );
      expect(frame, isNotNull);
      expect(frame!.type, TermFrameType.output);
      expect(frame.bytes, raw);
    });

    test('退出帧带退出码', () {
      final frame = TermFrame.decode('{"t":"x","code":130}');
      expect(frame!.type, TermFrameType.exited);
      expect(frame.exitCode, 130);
    });

    test('错误帧带文案', () {
      final frame = TermFrame.decode('{"t":"e","m":"会话已达 4 小时上限"}');
      expect(frame!.type, TermFrameType.error);
      expect(frame.message, contains('4 小时'));
    });

    test('非法载荷返回 null 而不是抛异常', () {
      expect(TermFrame.decode('not json'), isNull);
      expect(TermFrame.decode(123), isNull);
      expect(TermFrame.decode('{"t":"o","d":"%%%"}')!.type,
          TermFrameType.unknown);
    });
  });

  group('出站帧编码', () {
    test('输入字节 base64 往返一致', () {
      final bytes = <int>[0x03, 0x0d, 0x7f, 0xe4, 0xb8, 0xad];
      final payload = TermOut.input(bytes);
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['t'], 'i');
      expect(base64Decode(decoded['d'] as String), bytes);
    });

    test('resize 帧字段名与契约一致', () {
      final decoded =
          jsonDecode(TermOut.resize(cols: 44, rows: 18)) as Map<String, dynamic>;
      expect(decoded, <String, Object>{'t': 'r', 'c': 44, 'r': 18});
    });
  });

  group('Ctrl 粘滞键', () {
    test('小写字母转控制字符', () {
      expect(applyCtrl('c'), '\x03');
      expect(applyCtrl('d'), '\x04');
      expect(applyCtrl('a'), '\x01');
    });

    test('方括号到下划线按 ASCII 规则偏移', () {
      expect(applyCtrl('['), '\x1b');
      expect(applyCtrl(']'), '\x1d');
      expect(applyCtrl('_'), '\x1f');
    });

    test('非单字符与非字母返回 null（交给普通输入路径）', () {
      expect(applyCtrl('1'), isNull);
      expect(applyCtrl('ab'), isNull);
      expect(applyCtrl('中'), isNull);
      expect(applyCtrl(''), isNull);
    });
  });

  group('UTF-8 分帧', () {
    test('汉字被切成两帧时不产生替换字符', () {
      final chunks = <String>[];
      final sink = const Utf8Decoder(allowMalformed: true)
          .startChunkedConversion(_CollectSink(chunks.add));
      final bytes = utf8.encode('中');
      // 故意从多字节字符中间切开——PTY 分帧与字符边界无关，这是常态。
      sink.add(bytes.sublist(0, 1));
      expect(chunks, isEmpty, reason: '半个字符应先留在缓冲里，不吐给终端');
      sink.add(bytes.sublist(1));
      expect(chunks.join(), '中');
      expect(chunks.join(), isNot(contains('\uFFFD')));
    });
  });

  group('按键条', () {
    testWidgets('点 Esc 发出 0x1b，点 Ctrl 切换粘滞态', (WidgetTester tester) async {
      final sent = <String>[];
      var ctrl = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TerminalKeyBar(
                ctrlActive: ctrl,
                keyboardVisible: false,
                onKey: sent.add,
                onCtrlToggle: () => setState(() => ctrl = !ctrl),
                onKeyboardToggle: () {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Esc'));
      await tester.pumpAndSettle();
      expect(sent, <String>['\x1b']);

      await tester.tap(find.text('Ctrl'));
      await tester.pumpAndSettle();
      expect(ctrl, isTrue);
    });
  });
}

class _CollectSink implements Sink<String> {
  _CollectSink(this._onData);

  final void Function(String) _onData;

  @override
  void add(String data) => _onData(data);

  @override
  void close() {}
}
