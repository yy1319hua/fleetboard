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

  group('修饰键变换', () {
    test('Ctrl 走控制字符，Shift 只大写单字母，Alt 加 ESC 前缀', () {
      expect(applyModifiers('c', {TermModifier.ctrl}), '\x03');
      expect(applyModifiers('a', {TermModifier.shift}), 'A');
      expect(applyModifiers('x', {TermModifier.alt}), '\x1bx');
    });

    test('叠加顺序 Ctrl → Shift → Alt：Alt+Ctrl+C 是 ESC 后跟 0x03', () {
      expect(
        applyModifiers('c', {TermModifier.ctrl, TermModifier.alt}),
        '\x1b\x03',
      );
      // 已经被 Ctrl 转成控制字符后，Shift 不应再动它。
      expect(
        applyModifiers('c', {TermModifier.ctrl, TermModifier.shift}),
        '\x03',
      );
    });

    test('整串输入只受 Alt 影响，Shift 不会把 ls -la 变成 LS -LA', () {
      expect(applyModifiers('ls -la', {TermModifier.shift}), 'ls -la');
      expect(applyModifiers('ls -la', {TermModifier.alt}), '\x1bls -la');
    });

    test('修饰键对汉字无效时原样返回，不产生空字节', () {
      expect(applyModifiers('中', {TermModifier.ctrl}), '中');
      expect(applyModifiers('中', {TermModifier.shift}), '中');
    });

    test('空输入与空修饰集是恒等变换', () {
      expect(applyModifiers('', {TermModifier.ctrl}), '');
      expect(applyModifiers('ls', <TermModifier>{}), 'ls');
    });
  });

  group('功能键序列', () {
    test('无修饰时发给远端的都是裸序列', () {
      const none = <TermModifier>{};
      expect(functionKeySequence(TermFunctionKey.esc, none), '\x1b');
      expect(functionKeySequence(TermFunctionKey.tab, none), '\t');
      expect(functionKeySequence(TermFunctionKey.enter, none), '\r');
      expect(functionKeySequence(TermFunctionKey.minus, none), '-');
      expect(functionKeySequence(TermFunctionKey.colon, none), ':');
      expect(functionKeySequence(TermFunctionKey.ins, none), '\x1b[2~');
      expect(functionKeySequence(TermFunctionKey.end, none), '\x1b[F');
      expect(functionKeySequence(TermFunctionKey.up, none), '\x1b[A');
      expect(functionKeySequence(TermFunctionKey.down, none), '\x1b[B');
      expect(functionKeySequence(TermFunctionKey.right, none), '\x1b[C');
      expect(functionKeySequence(TermFunctionKey.left, none), '\x1b[D');
    });

    test('修饰键按 xterm 系数编码（1=Shift, 2=Alt, 4=Ctrl）', () {
      expect(csiModifierParam(<TermModifier>{}), 1);
      expect(csiModifierParam({TermModifier.shift}), 2);
      expect(csiModifierParam({TermModifier.alt}), 3);
      expect(csiModifierParam({TermModifier.ctrl}), 5);
      expect(
        csiModifierParam(
            {TermModifier.shift, TermModifier.alt, TermModifier.ctrl}),
        8,
      );
    });

    test('方向键与 End/Ins 带修饰时插入参数，不是简单拼字符串', () {
      expect(
        functionKeySequence(TermFunctionKey.up, {TermModifier.shift}),
        '\x1b[1;2A',
      );
      expect(
        functionKeySequence(TermFunctionKey.left, {TermModifier.ctrl}),
        '\x1b[1;5D',
      );
      expect(
        functionKeySequence(TermFunctionKey.end, {TermModifier.shift}),
        '\x1b[1;2F',
      );
      expect(
        functionKeySequence(TermFunctionKey.ins, {TermModifier.shift}),
        '\x1b[2;2~',
      );
    });

    test('Shift+Tab 是反向补全，Esc 永远单个 0x1b', () {
      expect(
        functionKeySequence(TermFunctionKey.tab, {TermModifier.shift}),
        '\x1b[Z',
      );
      expect(
        functionKeySequence(
            TermFunctionKey.esc, {TermModifier.ctrl, TermModifier.alt}),
        '\x1b',
      );
    });
  });

  group('按键条', () {
    Widget host(List<String> sent, void Function(Set<TermModifier>) onMods) {
      var mods = <TermModifier>{};
      return MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TerminalKeyBar(
              modifiers: mods,
              keyboardVisible: false,
              onKey: sent.add,
              onModifierToggle: (m) => setState(() {
                if (!mods.remove(m)) mods.add(m);
                onMods(mods);
              }),
              onKeyboardToggle: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('14 个键全部渲染，且不再有老版的 ^C 与方向图标混排', (tester) async {
      await tester.pumpWidget(host(<String>[], (_) {}));
      for (final label in <String>[
        'ESC', 'CTRL', 'ALT', 'INS', 'END', 'SHIFT', ':', '↑', '↓', '←', '→',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺键 $label');
      }
      expect(find.text('^C'), findsNothing);
    });

    testWidgets('点 ESC 发 0x1b，点 CTRL 点亮粘滞态', (tester) async {
      final sent = <String>[];
      var mods = <TermModifier>{};
      await tester.pumpWidget(host(sent, (m) => mods = m));

      await tester.tap(find.text('ESC'));
      await tester.pumpAndSettle();
      expect(sent, <String>['\x1b']);

      await tester.tap(find.text('CTRL'));
      await tester.pumpAndSettle();
      expect(mods, {TermModifier.ctrl});
    });

    testWidgets('360dp 竖屏下两行等宽、不溢出，方向键成十字', (tester) async {
      // 用最窄的常见竖屏宽度压一版：一加/红米这类 360dp 机是主流下限，
      // 这里能过，更宽的屏只会更松。
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(<String>[], (_) {}));
      expect(tester.takeException(), isNull, reason: '出现溢出');

      final up = tester.getCenter(find.text('↑'));
      final down = tester.getCenter(find.text('↓'));
      final left = tester.getCenter(find.text('←'));
      final right = tester.getCenter(find.text('→'));

      // 十字：↑↓ 同列；← ↓ → 同一行且左右夹住 ↓。
      expect(up.dx, closeTo(down.dx, 0.5));
      expect(left.dy, closeTo(down.dy, 0.5));
      expect(right.dy, closeTo(down.dy, 0.5));
      expect(left.dx, lessThan(down.dx));
      expect(right.dx, greaterThan(down.dx));
      // 上下两行：↑ 在上、↓ 在下，间距等于一个 os 行高（34）。
      expect(down.dy - up.dy, closeTo(TerminalKeyBar.rowHeight, 0.5));

      // 7 列等宽：每格宽 = (360 - 34) / 7 ≈ 46.6。
      final esc = tester.getRect(find.text('ESC'));
      final ins = tester.getRect(find.text('INS'));
      expect(esc.width, greaterThan(0));
      expect(ins.width, greaterThan(0));
      expect((360 - 34) / 7, greaterThan(40));
    });

    testWidgets('SHIFT 亮着点 ↑ 发 CSI 1;2A，不是裸方向键', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(host(sent, (_) {}));

      await tester.tap(find.text('SHIFT'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('↑'));
      await tester.pumpAndSettle();
      expect(sent, <String>['\x1b[1;2A']);
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
