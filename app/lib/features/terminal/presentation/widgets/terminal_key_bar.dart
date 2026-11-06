import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/design_tokens.dart';

/// 终端修饰键。
///
/// 三个可以**叠加**：Ctrl+Alt+字符、Shift+Ctrl+方向键都是终端里的真实用法
/// （`Alt+.` 取上条命令末参数、`Shift+方向` 选中、`Ctrl+Shift+A` 之类）。
/// 但每个都只作用于**下一次输入**，用完即灭——理由见 [applyModifiers]。
enum TermModifier { ctrl, alt, shift }

/// 按键条上的非字符键。
enum TermFunctionKey {
  esc,
  tab,
  enter,
  minus,
  colon,
  ins,
  end,
  up,
  down,
  left,
  right,
}

/// 终端按键条：软键盘上没有的那几个键。
///
/// 为什么必须有它：手机输入法只给字母数字，而 shell 里 `Esc`（切 vim 模式、
/// 取消当前行）、`Tab`（补全）、`Ctrl-C`（中断）、方向键（翻历史、TUI 内移动）
/// 全是高频操作。没有这一排，终端在手机上只剩「敲一行命令回车」这一种用法，
/// 稍微复杂一点的操作就得换电脑——这正是「有的 shell 做了根本没法用」的由来。
///
/// 排布是 7 列 × 2 行，方向键摆成十字：
/// ```
/// ESC  ⇥  CTRL  ALT  −   ↑   ↵
/// INS END SHIFT  :    ←   ↓   →
/// ```
/// 上下行各 7 格、等宽均分，↑ 与 ↓ 同列、← 与 → 夹住 ↓——这套排布的可贵之处
/// 是**手指不用找**：方向键在任何输入场景里都是肌肉记忆，打散重排等于每次都要
/// 重新定位。右侧窄条单独放键盘开关，不占 7 格里的任何一格。
class TerminalKeyBar extends StatelessWidget {
  const TerminalKeyBar({
    super.key,
    required this.modifiers,
    required this.keyboardVisible,
    required this.onModifierToggle,
    required this.onKey,
    required this.onKeyboardToggle,
  });

  /// 当前点亮的修饰键（粘滞态，未消费）。
  final Set<TermModifier> modifiers;
  final bool keyboardVisible;
  final ValueChanged<TermModifier> onModifierToggle;
  final ValueChanged<String> onKey;
  final VoidCallback onKeyboardToggle;

  /// 单行高度。
  ///
  /// 34 → 30 是按实际使用反馈收敛的：竖屏 + 键盘弹起时这 4dp×2 直接换成一整行
  /// 终端输出，比留在按键上更值。代价是触控区低于 Material 建议的 48dp——
  /// 但按键条是「高频短按、手指有肌肉记忆」的场景，误触代价只是多敲一个
  /// 控制字符，与「少一行可见输出」相比可以接受。
  static const double rowHeight = 30;

  static const String esc = '\x1b';
  static const String tab = '\t';
  static const String enter = '\r';
  static const String backspace = '\x7f';

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.s1,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _row(<Widget>[
                  _textKey('ESC', () => _fire(TermFunctionKey.esc)),
                  _iconKey(Icons.keyboard_tab,
                      () => _fire(TermFunctionKey.tab)),
                  _modifierKey('CTRL', TermModifier.ctrl),
                  _modifierKey('ALT', TermModifier.alt),
                  _iconKey(Icons.remove, () => _fire(TermFunctionKey.minus)),
                  _textKey('↑', () => _fire(TermFunctionKey.up), glyph: true),
                  _iconKey(Icons.keyboard_return,
                      () => _fire(TermFunctionKey.enter), accent: true),
                ]),
                _row(<Widget>[
                  _textKey('INS', () => _fire(TermFunctionKey.ins)),
                  _textKey('END', () => _fire(TermFunctionKey.end)),
                  _modifierKey('SHIFT', TermModifier.shift),
                  _textKey(':', () => _fire(TermFunctionKey.colon), glyph: true),
                  _textKey('←', () => _fire(TermFunctionKey.left), glyph: true),
                  _textKey('↓', () => _fire(TermFunctionKey.down), glyph: true),
                  _textKey('→', () => _fire(TermFunctionKey.right),
                      glyph: true),
                ]),
              ],
            ),
          ),
          _keyboardStrip(context),
        ],
      ),
    );
  }

  /// 按下一个功能键：先按当前修饰态算出真实序列，再交给页面发送。
  ///
  /// 页面对 `onKey` 的约定是「序列已完整，直接发」——修饰键的变换在这里一次
  /// 做完，页面不再重复解释，避免两处各算一半。
  void _fire(TermFunctionKey key) {
    HapticFeedback.selectionClick();
    onKey(functionKeySequence(key, modifiers));
  }

  Widget _row(List<Widget> children) =>
      SizedBox(height: rowHeight, child: Row(children: children));

  Widget _textKey(String label, VoidCallback onTap, {bool glyph = false}) {
    return _slot(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.muted,
          // 箭头/冒号这类单字符放大一点才看得清，字母键保持 eyebrow 字号，
          // 否则 'SHIFT' 这种五字词在 51dp 宽里会被压扁。
          fontSize: glyph ? AppFontSizes.h3 : AppFontSizes.eyebrow,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _iconKey(
    IconData icon,
    VoidCallback onTap, {
    bool accent = false,
  }) {
    return _slot(
      onTap: onTap,
      child: Icon(
        icon,
        size: 18,
        color: accent ? AppColors.accent : AppColors.muted,
      ),
    );
  }

  /// 修饰键：点亮时常驻底色 + 底部亮边，和普通键一眼可分。
  Widget _modifierKey(String label, TermModifier m) {
    final on = modifiers.contains(m);
    return _slot(
      onTap: () {
        HapticFeedback.selectionClick();
        onModifierToggle(m);
      },
      active: on,
      child: Text(
        label,
        style: TextStyle(
          color: on ? AppColors.accent : AppColors.muted,
          fontSize: AppFontSizes.eyebrow,
          fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _slot({
    required VoidCallback onTap,
    required Widget child,
    bool active = false,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
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
            child: child,
          ),
        ),
      ),
    );
  }

  /// 右侧窄条：键盘开关跨两行，不占 7 格里的任何一格。
  ///
  /// 它是整条里唯一「不发给远端」的键，混在 14 格里容易被当成 `^C` 之类误触；
  /// 单独一条 + 左侧分隔线，语义上就分开了。
  Widget _keyboardStrip(BuildContext context) {
    return Container(
      width: 34,
      height: rowHeight * 2,
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onKeyboardToggle();
        },
        child: Center(
          child: Icon(
            keyboardVisible
                ? Icons.keyboard_hide_outlined
                : Icons.keyboard_outlined,
            size: 18,
            color: AppColors.faint,
          ),
        ),
      ),
    );
  }
}

/// xterm 的修改键参数：`1 + Shift + 2·Alt + 4·Ctrl`。
///
/// 这个系数不是随手定的，是 xterm 的 CSI 编码约定：等于 1 时会省略参数
/// （`\x1b[A` 与 `\x1b[1;1A` 语义相同，但后者老终端不认），所以调用方要按
/// 「等于 1 就不写」处理。
int csiModifierParam(Set<TermModifier> mods) {
  var m = 1;
  if (mods.contains(TermModifier.shift)) m += 1;
  if (mods.contains(TermModifier.alt)) m += 2;
  if (mods.contains(TermModifier.ctrl)) m += 4;
  return m;
}

/// 功能键 → 实际发给远端的字节序列。
///
/// 说明几个不那么显然的：
/// - `Esc` 本身就是前缀，再挂修饰没有意义，永远发单个 0x1b。
/// - `Tab` 只有 Shift 组合有通用约定（`\x1b[Z`，反向补全）；Ctrl/Alt+Tab 各家
///   实现不一，发裸 `\t` 至少不会让远端读到乱码。
/// - `INS`/`END` 用 `\x1b[2~` / `\x1b[F`：前者是 VT220 起的通行写法，后者比
///   `\x1b[4~` 兼容面更广（Linux 控制台、xterm、tmux 都认）。
/// - 减号与冒号是普通字符，走 [applyModifiers]，这样 `Alt+-` 能发出 `\x1b-`。
String functionKeySequence(TermFunctionKey key, Set<TermModifier> mods) {
  switch (key) {
    case TermFunctionKey.esc:
      return TerminalKeyBar.esc;
    case TermFunctionKey.enter:
      return TerminalKeyBar.enter;
    case TermFunctionKey.tab:
      return mods.contains(TermModifier.shift) ? '\x1b[Z' : TerminalKeyBar.tab;
    case TermFunctionKey.minus:
      return applyModifiers('-', mods);
    case TermFunctionKey.colon:
      return applyModifiers(':', mods);
    case TermFunctionKey.ins:
      return _csiTilde(2, mods);
    case TermFunctionKey.end:
      return _csiLetter('F', mods);
    case TermFunctionKey.up:
      return _csiLetter('A', mods);
    case TermFunctionKey.down:
      return _csiLetter('B', mods);
    case TermFunctionKey.right:
      return _csiLetter('C', mods);
    case TermFunctionKey.left:
      return _csiLetter('D', mods);
  }
}

String _csiLetter(String letter, Set<TermModifier> mods) {
  final m = csiModifierParam(mods);
  return m == 1 ? '\x1b[$letter' : '\x1b[1;$m$letter';
}

String _csiTilde(int n, Set<TermModifier> mods) {
  final m = csiModifierParam(mods);
  return m == 1 ? '\x1b[$n~' : '\x1b[$n;$m~';
}

/// 把修饰键作用到一段普通输入上，返回真正要发的字节。
///
/// 修饰键是**粘滞**的：用完立刻熄灭，不做常亮。常亮会让人想敲 `ls` 却发出
/// `\x0c\x13`（清屏 + 暂停输出），屏幕上看起来就是终端卡死——这个坑比
/// 「每次组合都要多点一下」的代价大得多。
///
/// 顺序是 Ctrl → Shift → Alt：
/// - 先 Ctrl 把 `c` 转成 0x03；
/// - 再 Shift 只对单个小写字母做大写化，整串输入不动（`ls -la` 不该变 `LS -LA`）；
/// - Alt 最后加 ESC 前缀，所以 `Alt+Ctrl+C` 得到 `\x1b\x03`，正是 xterm 的约定。
String applyModifiers(String data, Set<TermModifier> mods) {
  if (data.isEmpty || mods.isEmpty) return data;
  var out = data;
  if (mods.contains(TermModifier.ctrl)) {
    out = applyCtrl(out) ?? out;
  }
  if (mods.contains(TermModifier.shift) && out.length == 1) {
    final code = out.codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) out = out.toUpperCase();
  }
  if (mods.contains(TermModifier.alt)) {
    out = '\x1b$out';
  }
  return out;
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
