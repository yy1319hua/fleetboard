import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/theme/design_tokens.dart';
import '../../auth/application/auth_notifier.dart';
import '../../overview/application/overview_notifier.dart';
import '../data/terminal_client.dart';
import 'widgets/terminal_key_bar.dart';

/// 服务器终端（交互式 shell）。
///
/// 竖屏优先——这是本页几乎所有取舍的来源：
///
/// 1. **软键盘弹出时收起 AppBar**。竖屏 + 软键盘会吃掉约 300dp，顶部再占 56dp
///    的标题栏，终端就只剩七八行，`htop`/`vim` 完全没法看。键盘在时把标题栏
///    让出去，键盘收起（点按键条最右的键盘图标）标题栏自动回来。
/// 2. **按键条常驻**，且不横向滚动。软键盘上没有 Esc/Tab/Ctrl/方向键，
///    没有这一排就只剩「敲一行命令回车」。
/// 3. **断线不自动重连**。重连回来的是新 shell，cwd 和环境变量都变了；
///    悄悄换掉比明确报错更坑。
/// 4. **字号可调**。12 号在 360dp 屏上约 44 列，命令行工具大多按 80 列排版，
///    放宽到 14 能多塞几列，但小字看久了费眼——交给用户自己定。
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key, required this.serverId});

  final int serverId;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  static const int _minFont = 10;
  static const int _maxFont = 18;
  static const int _maxScrollback = 2000;

  late final Terminal _terminal = Terminal(maxLines: _maxScrollback);
  final FocusNode _focus = FocusNode();

  TerminalClient? _client;
  ByteConversionSink? _decodeSink;
  bool _started = false;
  bool _ctrl = false;
  int _fontSize = 12;
  String? _closedReason;
  int? _exitCode;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _handleTerminalOutput;
    _terminal.onResize = (w, h, _, __) => _client?.requestResize(w, h);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      // 推迟到首帧之后：这时 MediaQuery 与主题都已就绪，能按真实可用区域
      // 估算行列；TerminalView 的 autoResize 会很快用实际网格再校正一次。
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  @override
  void dispose() {
    _client?.dispose();
    _decodeSink?.close();
    _focus.dispose();
    super.dispose();
  }

  /// 首连时的行列估算。
  ///
  /// 估算而不是等布局完成：PTY 必须在 shell 启动前拿到尺寸，否则远端会先按
  /// 80x24 起一个 shell，等我们 resize 时，已经打印过的 `neofetch` 之类
  /// 输出是排错的，重排会留下错位的空行。
  ({int cols, int rows}) _estimateGrid() {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final charW = _fontSize * 0.6; // 等宽字体的常见宽高比
    final lineH = _fontSize * 1.3;
    final usableW = size.width - 12;
    final usableH = size.height - mq.padding.top - mq.padding.bottom -
        kToolbarHeight - 40;
    final cols = (usableW / charW).floor().clamp(20, 500);
    final rows = (usableH / lineH).floor().clamp(5, 200);
    return (cols: cols, rows: rows);
  }

  void _connect() {
    final session = ref.read(authNotifierProvider).session;
    if (session == null) {
      setState(() => _closedReason = '登录状态已失效，请重新登录');
      return;
    }
    final grid = _estimateGrid();

    // 每次都新建解码器：断线重连后残留的半个多字节字符不能带进新会话。
    // startChunkedConversion 返回的是「喂字节」的 sink，半个字符留在其内部
    // 缓冲区里等下一帧补齐，而不是立刻变成 U+FFFD。
    _decodeSink = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_CallbackSink(_terminal.write));

    final client = TerminalClient(
      baseUrl: session.baseUrl,
      token: session.accessToken,
      serverId: widget.serverId,
      cols: grid.cols,
      rows: grid.rows,
      onOutput: (Uint8List bytes) => _decodeSink?.add(bytes),
      onExit: (int code) {
        if (!mounted) return;
        setState(() => _exitCode = code);
      },
      onClosed: (String reason) {
        if (!mounted) return;
        setState(() => _closedReason = reason);
      },
    );
    _client = client;
    client.connect();
  }

  /// 终端要发送的字节。
  ///
  /// Ctrl 粘滞键在这里生效：点亮后只作用于**下一个字符**，随即自动熄灭。
  /// 不做「Ctrl 常亮」是因为终端里 Ctrl 组合远少于普通输入，常亮会导致
  /// 想敲 `ls` 却发出 `\x0c\x13`（清屏 + 暂停输出），看起来像终端卡死。
  void _handleTerminalOutput(String data) {
    if (_ctrl) {
      final converted = applyCtrl(data);
      if (converted != null) {
        _client?.sendInput(utf8.encode(converted));
        if (mounted) setState(() => _ctrl = false);
        return;
      }
    }
    _client?.sendInput(utf8.encode(data));
  }

  void _sendKey(String sequence) => _client?.sendInput(utf8.encode(sequence));

  void _toggleCtrl() => setState(() => _ctrl = !_ctrl);

  void _toggleKeyboard() {
    if (_focus.hasFocus) {
      _focus.unfocus();
    } else {
      _focus.requestFocus();
    }
  }

  void _changeFont(int delta) {
    final next = (_fontSize + delta).clamp(_minFont, _maxFont);
    if (next == _fontSize) return;
    setState(() => _fontSize = next);
    // 字号变了，网格随之变化；TerminalView 会触发 onResize 自动同步给远端。
  }

  void _reconnect() {
    _client?.dispose();
    setState(() {
      _closedReason = null;
      _exitCode = null;
    });
    _terminal.write('\r\n\x1b[38;5;179m[重新连接]\x1b[0m\r\n');
    _connect();
  }

  String get _serverName {
    final servers = ref.watch(overviewProvider).value?.servers ?? const [];
    final s = servers.where((e) => e.id == widget.serverId).firstOrNull;
    return s?.name ?? '服务器 #${widget.serverId}';
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
    final disconnected = _closedReason != null;

    return Scaffold(
      backgroundColor: AppColors.terminal,
      // 键盘弹出时让出标题栏（见类注释第 1 条）。
      appBar: keyboardVisible
          ? null
          : AppBar(
              backgroundColor: AppColors.s1,
              title: Row(
                children: <Widget>[
                  _statusDot(disconnected),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _serverName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: AppFontSizes.body),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '终端',
                    style: TextStyle(
                      fontSize: AppFontSizes.caption,
                      color: AppColors.faint,
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: '缩小字号',
                  onPressed: _fontSize > _minFont ? () => _changeFont(-1) : null,
                  icon: const Icon(Icons.text_decrease, size: 20),
                ),
                IconButton(
                  tooltip: '放大字号',
                  onPressed: _fontSize < _maxFont ? () => _changeFont(1) : null,
                  icon: const Icon(Icons.text_increase, size: 20),
                ),
              ],
            ),
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              Expanded(
                child: TerminalView(
                  _terminal,
                  focusNode: _focus,
                  // 关掉自动滚动模拟：竖屏下滚动语义由用户手势决定，
                  // 模拟会把「向上滑看历史」翻译成方向键，在 vim 里直接跑飞。
                  simulateScroll: false,
                  // AOSP 系输入法的退格不发硬件删除事件（xterm.dart #201），
                  // 打开这个兜底检测，否则 HeliBoard/OpenBoard 用户按退格没反应。
                  deleteDetection: true,
                  // 默认 emailAddress 键盘：没有候选词条与自动纠错。
                  // Gboard 的自动纠错会把 `ls -la` 改成 `Is -la`（xterm.dart #176），
                  // 这是移动端终端最常见的一类「打出来的命令不对」。
                  keyboardType: TextInputType.emailAddress,
                  textStyle: TerminalStyle(
                    fontSize: _fontSize.toDouble(),
                    height: 1.3,
                    fontFamily: 'monospace',
                  ),
                  theme: _terminalTheme,
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                ),
              ),
              TerminalKeyBar(
                ctrlActive: _ctrl,
                keyboardVisible: keyboardVisible,
                onKey: _sendKey,
                onCtrlToggle: _toggleCtrl,
                onKeyboardToggle: _toggleKeyboard,
              ),
            ],
          ),
          if (disconnected)
            Positioned.fill(
              child: _DisconnectedOverlay(
                reason: _closedReason!,
                exitCode: _exitCode,
                onReconnect: _reconnect,
                onLeave: () => Navigator.of(context).maybePop(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusDot(bool disconnected) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: disconnected ? AppColors.danger : AppColors.ok,
        shape: BoxShape.circle,
      ),
    );
  }

  TerminalTheme get _terminalTheme => const TerminalTheme(
        cursor: AppColors.accent,
        selection: AppColors.accentSoft,
        foreground: AppColors.text,
        background: AppColors.terminal,
        black: Color(0xFF1F242C),
        red: Color(0xFFF85149),
        green: Color(0xFF3FB950),
        yellow: Color(0xFFD29922),
        blue: Color(0xFF58A6FF),
        magenta: Color(0xFFBC8CFF),
        cyan: Color(0xFF39C5CF),
        white: Color(0xFFB1BAC4),
        brightBlack: Color(0xFF6E7681),
        brightRed: Color(0xFFFF7B72),
        brightGreen: Color(0xFF56D364),
        brightYellow: Color(0xFFE3B341),
        brightBlue: Color(0xFF79C0FF),
        brightMagenta: Color(0xFFD2A8FF),
        brightCyan: Color(0xFF56D4DD),
        brightWhite: Color(0xFFF0F6FC),
        searchHitBackground: Color(0x66E8A33D),
        searchHitBackgroundCurrent: Color(0xCCE8A33D),
        searchHitForeground: AppColors.textInverse,
      );
}

/// 断线遮罩：说清楚发生了什么，并给两条明确出路。
///
/// 不自动重连的原因见 [TerminalClient] 注释；这里补一条 UI 上的考虑：
/// 断线时如果只是把界面冻住，用户会以为是自己敲错了或者机器卡了，
/// 所以必须显式说「连接已断开」。
class _DisconnectedOverlay extends StatelessWidget {
  const _DisconnectedOverlay({
    required this.reason,
    required this.exitCode,
    required this.onReconnect,
    required this.onLeave,
  });

  final String reason;
  final int? exitCode;
  final VoidCallback onReconnect;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final normalExit = exitCode == 0;
    return ColoredBox(
      color: const Color(0xCC0B0D10),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          decoration: BoxDecoration(
            color: AppColors.s1,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    normalExit ? Icons.check_circle_outline : Icons.link_off,
                    size: 18,
                    color: normalExit ? AppColors.ok : AppColors.danger,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    normalExit ? '会话已结束' : '连接已断开',
                    style: const TextStyle(
                      fontSize: AppFontSizes.body,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                exitCode != null ? '$reason（退出码 $exitCode）' : reason,
                style: const TextStyle(
                  fontSize: AppFontSizes.bodySm,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '重新连接会开一个新的 shell，之前的工作目录与环境变量不会保留。',
                style: TextStyle(
                  fontSize: AppFontSizes.caption,
                  color: AppColors.faint,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onLeave,
                      child: const Text('退出'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: onReconnect,
                      child: const Text('重新连接'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 解码器出口：每解出一段文本就写进终端缓冲区。
class _CallbackSink implements Sink<String> {
  _CallbackSink(this._onData);

  final void Function(String) _onData;

  @override
  void add(String data) => _onData(data);

  @override
  void close() {}
}
