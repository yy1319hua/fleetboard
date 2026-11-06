import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/design_tokens.dart';

/// 终端按键条：软键盘上没有的那几个键。
///
/// 为什么必须有它：手机输入法只给字母数字，而 shell 里 `Esc`（切 vim 模式、
/// 取消当前行）、`Tab`（补全）、`Ctrl-C`（中断）、方向键（翻历史、TUI 内移动）
/// 全是高频操作。没有这一排，终端在手机上只剩「敲一行命令回车」这一种用法，
/// 稍微复杂一点的操作就得换电脑——这正是「有的 shell 做了根本没法用」的由来。
///
/// 不做横向滚动：藏起来的键等于不存在。10 个键用 Expanded 均分，
/// 360dp 屏上每位约 36dp，够点。
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.ctrlActive,
    required this.onKey,
    required this.onCtrlToggle,
    required this.onKeyboardToggle,
    required this.keyboardVisible,
  });

  /// Ctrl 是否处于「粘滞」状态：点亮后只作用下一个字符，随即自动熄灭。
  final bool ctrlActive;
  final void Function(String sequence) onKey;
  final VoidCallback onCtrlToggle;
  final VoidCallback onKeyboardToggle;
  final bool keyboardVisible;

  /// 控制序列都用转义写法，避免在源码里出现不可见字符。
  static const String esc = '\x1b';
  static const String tab = '\t';
  static const String backspace = '\x7f';
  static const String ctrlC = '\x03';
  static const String up = '\x1b[A';
  static const String down = '\x1b[B';
  static const String right = '\x1b[C';
  static const String left = '\x1b[D';

  @override
  Widget build(BuildContext context) {
    // 行高固定 40：再高会明显挤压可用终端区（竖屏 + 软键盘时本来就只剩十来行），
    // 再矮则低于可点阈值，误触率上升。
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: AppColors.s1,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          _key(context, 'Esc', () => onKey(esc)),
          _key(context, 'Tab', () => onKey(tab)),
          _key(
            context,
            'Ctrl',
            onCtrlToggle,
            active: ctrlActive,
          ),
          _key(context, '^C', () => onKey(ctrlC), danger: true),
          _iconKey(context, Icons.keyboard_arrow_left, () => onKey(left)),
          _iconKey(context, Icons.keyboard_arrow_up, () => onKey(up)),
          _iconKey(context, Icons.keyboard_arrow_down, () => onKey(down)),
          _iconKey(context, Icons.keyboard_arrow_right, () => onKey(right)),
          _iconKey(context, Icons.backspace_outlined, () => onKey(backspace)),
          _iconKey(
            context,
            keyboardVisible ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined,
            onKeyboardToggle,
          ),
        ],
      ),
    );
  }

  Widget _key(
    BuildContext context,
    String label,
    VoidCallback onTap, {
    bool active = false,
    bool danger = false,
  }) {
    final color = active
        ? AppColors.accent
        : danger
            ? AppColors.danger
            : AppColors.muted;
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          alignment: Alignment.center,
          decoration: active
              ? const BoxDecoration(
                  color: AppColors.accentSoft,
                  border: Border(
                    bottom: BorderSide(color: AppColors.accent, width: 2),
                  ),
                )
              : null,
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: AppFontSizes.caption,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconKey(BuildContext context, IconData icon, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Icon(icon, size: 18, color: AppColors.muted),
      ),
    );
  }
}

/// Ctrl 粘滞键的字符变换：把 `c` 变成 0x03。
///
/// 放在纯函数里而不是页面里，是因为这段逻辑的边界（多字节字符、组合输入、
/// 非小写字母）必须能单测覆盖——终端里错发一个控制字符，可能直接是
/// `Ctrl-D` 把会话关掉。
String? applyCtrl(String data) {
  if (data.length != 1) return null;
  final code = data.codeUnitAt(0);
  // 只处理 a-z 与 [ \ ] ^ _ @，其余原样返回 null 交给调用方按普通输入发。
  if (code >= 0x61 && code <= 0x7a) {
    return String.fromCharCode(code - 0x60);
  }
  if (code == 0x40) return String.fromCharCode(0x00); // Ctrl-@ = NUL
  if (code >= 0x5b && code <= 0x5f) {
    return String.fromCharCode(code - 0x40);
  }
  return null;
}
