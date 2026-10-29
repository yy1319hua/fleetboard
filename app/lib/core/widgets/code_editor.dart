import 'package:flutter/material.dart';

/// 带行号的等宽文本编辑器。
///
/// 为什么不用 `TextField(maxLines: null)` 直接了事：
///  - 看 YAML / 配置文件时一旦超过一屏，没有行号就无法和 diff、报错行号对应起来；
///  - 行号列必须与正文**逐像素对齐**，所以两者共用同一个滚动控制器——
///    各自维护滚动位置的话，滚动时行号会逐渐偏移，久了完全对不上。
///
/// 对齐靠 [strutStyle] 强制固定行高：字体上下浮动（如中文回退字体）会让行高不一致，
/// 行号从第十几行开始就会错位。
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.controller,
    this.readOnly = false,
    this.hintText,
    this.fontSize = 13,
    this.onChanged,
  });

  final TextEditingController controller;
  final bool readOnly;
  final String? hintText;
  final double fontSize;
  final ValueChanged<String>? onChanged;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  final ScrollController _scroll = ScrollController();

  /// 行高固定：行号列与正文都按这个值排版，才能逐行对齐。
  static const double _lineHeightFactor = 1.45;
  static const double _verticalPadding = 10;

  double get _lineHeight => widget.fontSize * _lineHeightFactor;

  @override
  void initState() {
    super.initState();
    // 文本变化要重算行号数量。
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = widget.controller.text;
    // 末行为空时也要显示行号（用户刚敲回车），所以按 split 结果计数即可。
    final lineCount = text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;
    final gutterWidth = (lineCount.toString().length * 8.0) + 20;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: gutterWidth,
            child: ClipRect(
              child: ListenableBuilder(
                listenable: _scroll,
                builder: (context, _) {
                  final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                  return Padding(
                    padding: const EdgeInsets.only(top: _verticalPadding),
                    child: Transform.translate(
                      offset: Offset(0, -offset),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List<Widget>.generate(
                          lineCount,
                          (i) => SizedBox(
                            height: _lineHeight,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: widget.fontSize - 2,
                                  height: _lineHeightFactor,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              scrollController: _scroll,
              readOnly: widget.readOnly,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              // YAML 缩进敏感：关掉自动纠错与联想替换，避免把 `-` 变成 `–`。
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Roboto Mono', 'Menlo'],
                fontSize: widget.fontSize,
                height: _lineHeightFactor,
              ),
              strutStyle: StrutStyle(
                fontSize: widget.fontSize,
                height: _lineHeightFactor,
                forceStrutHeight: true,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hintText,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: _verticalPadding,
                ),
              ),
              onChanged: widget.onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
