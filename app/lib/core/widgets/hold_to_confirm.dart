import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 长按确认控件（1.5s 持续按压才触发）。
///
/// 为什么用「长按」而不是二次弹窗确认：
///  - Compose `down`、容器删除这类操作**不可撤销**，但受害者是「误触」而不是「误判」。
///    二次弹窗对误触的拦截力很弱（用户肌肉记忆会直接点「确定」），对它唯一的
///    好处是慢；长按则是持续动作，误触会自动中断。
///  - 弹窗需要额外一次全屏跳转，而这两个操作常在滚动列表里发生，
///    用户需要先记住自己在哪一行，长按不会丢失上下文。
///
/// 触发后**不自动复位**：复位由调用方在操作结束后重建组件，
/// 否则用户会在同一位置连点两次（第一次已触发，第二次又触发）。
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.icon = Icons.warning_amber_rounded,
    this.holdDuration = const Duration(milliseconds: 1500),
    this.enabled = true,
    this.dense = false,
  });

  final String label;
  final VoidCallback onConfirmed;
  final IconData icon;
  final Duration holdDuration;
  final bool enabled;

  /// 紧凑模式：用于列表行内（高度更小）。
  final bool dense;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.holdDuration,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    if (!widget.enabled) return;
    HapticFeedback.mediumImpact();
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (_controller.value >= 1.0) {
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
      }
    });
  }

  void _cancel() {
    if (_controller.isAnimating) _controller.stop();
    _controller.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.enabled
        ? theme.colorScheme.error
        : theme.colorScheme.outline;
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _cancel(),
      onLongPressCancel: _cancel,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final progress = _controller.value;
          return Stack(
            children: [
              Container(
                height: widget.dense ? 40 : 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withAlpha(120)),
                  color: color.withAlpha(progress > 0 ? 24 : 10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: widget.dense ? 16 : 18, color: color),
                    const SizedBox(width: 6),
                    Text(
                      progress > 0 ? '继续按住…' : widget.label,
                      style: theme.textTheme.labelLarge?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
              // 进度条压在底边，比转圈更能表达「还要按多久」。
              if (progress > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: Colors.transparent,
                      color: color,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 一次性倒计时确认条：用于「高危但需要看提示」的场景（比长按轻，比弹窗重）。
///
/// 进入后 [seconds] 秒内按钮禁用并显示倒计时，倒计时结束才可点击。
/// 与 [HoldToConfirm] 的区别：这个用于「需要读一段文字」的场景（例如回滚说明），
/// 长按用于「不需要读、只需要别手滑」的场景。
class CountdownConfirmButton extends StatefulWidget {
  const CountdownConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.seconds = 3,
  });

  final String label;
  final VoidCallback onConfirmed;
  final int seconds;

  @override
  State<CountdownConfirmButton> createState() => _CountdownConfirmButtonState();
}

class _CountdownConfirmButtonState extends State<CountdownConfirmButton> {
  late int _remaining = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_remaining <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _remaining <= 0;
    return FilledButton(
      onPressed: ready ? widget.onConfirmed : null,
      child: Text(ready ? widget.label : '${widget.label}（$_remaining）'),
    );
  }
}
