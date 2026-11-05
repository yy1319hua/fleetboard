import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局统一的刷新按钮。
///
/// 为什么不用裸 `IconButton(Icons.refresh)`：接口快的时候整次刷新不到 100ms，
/// 图标一闪而过，用户根本看不出按下去有没有生效——这正是「按了不明显」的来源。
/// 这里把三件事绑在一起：
/// 1. 按下瞬间图标换成进度圈，先给「已经收到」的反馈，不等接口；
/// 2. 轻震一下，手指有触觉确认；
/// 3. 无论接口多快，进度圈至少转 [minSpin]，让「正在刷新」这件事看得见。
///
/// 刷新中按钮禁用，避免连点打出一串并发请求。
class RefreshIconButton extends StatefulWidget {
  const RefreshIconButton({
    super.key,
    required this.onRefresh,
    this.tooltip = '刷新',
    this.iconSize = 22,
    this.label,
    this.inline = false,
  });

  /// 刷新动作。应当等到数据真正到手再返回——进度圈的消失时刻就是它完成的时刻。
  final Future<void> Function() onRefresh;
  final String tooltip;
  final double iconSize;

  /// 非空时渲染带文字的按钮，文字即此值（错误态的「重试」）。
  /// 为空时是纯图标按钮（空态）。两种形态共享同一套转圈 + 触觉反馈。
  final String? label;

  /// [label] 非空且 inline=true 时用轻量 TextButton.icon（行内错误条），
  /// 否则用 FilledButton.tonalIcon（整页错误态，更醒目）。
  final bool inline;

  /// 进度圈的最短显示时长。
  static const Duration minSpin = Duration(milliseconds: 600);

  @override
  State<RefreshIconButton> createState() => _RefreshIconButtonState();
}

class _RefreshIconButtonState extends State<RefreshIconButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    // 触觉反馈先发，再改状态：手指的确认比画面更早到。
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final startedAt = DateTime.now();
    try {
      await widget.onRefresh();
    } catch (error, stack) {
      // 失败不在这里弹提示：数据层的错误各有各的说法（空态、错误条、重试按钮），
      // 页面上已经能看到。这里只负责让按钮恢复，别让它永远转下去。
      debugPrint('refresh failed: $error\n$stack');
    }
    final elapsed = DateTime.now().difference(startedAt);
    final remain = RefreshIconButton.minSpin - elapsed;
    if (remain > Duration.zero) {
      await Future<void>.delayed(remain);
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: _busy
          ? SizedBox(
              key: const ValueKey<String>('busy'),
              width: widget.iconSize - 3,
              height: widget.iconSize - 3,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                // 禁用态按钮会降低不透明度，进度圈要自己给足对比度。
                color: color,
              ),
            )
          : Icon(
              key: const ValueKey<String>('idle'),
              Icons.refresh,
              size: widget.iconSize,
            ),
    );
    final onPressed = _busy ? null : _run;
    final tooltip = _busy ? '正在刷新…' : widget.tooltip;

    final label = widget.label;
    if (label != null) {
      // 带文字形态：错误态 / 行内错误条。保留可见文案，同时接管
      // 600ms 转圈与触觉反馈，避免「同一产品两种刷新手感」。
      if (widget.inline) {
        return TextButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: Text(label),
        );
      }
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: icon,
        label: Text(label),
      );
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
    );
  }
}
