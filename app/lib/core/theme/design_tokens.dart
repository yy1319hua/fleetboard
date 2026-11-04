// GENERATED FILE — DO NOT EDIT.
// 由 scripts/gen_design_tokens.py 从 design/tokens.json 生成。
// 唯一真源是 design/tokens.json；CI 以 --check 校验本文件未漂移。

import 'package:flutter/material.dart';

/// 色板。值与 web/DESIGN.md §2、web/src/index.css 完全同源。
class AppColors {
  const AppColors._();

  static const Color bg = Color(0xFF0F1115);
  static const Color s1 = Color(0xFF161A21);
  static const Color s2 = Color(0xFF1D222B);
  static const Color s3 = Color(0xFF242A35);
  static const Color border = Color(0xFF2A303B);
  static const Color borderStrong = Color(0xFF3A4250);
  static const Color terminal = Color(0xFF0B0D10);
  static const Color text = Color(0xFFE6E9EF);
  static const Color muted = Color(0xFF9AA4B2);
  static const Color faint = Color(0xFF808A98);
  static const Color textInverse = Color(0xFF0F1115);
  static const Color accent = Color(0xFFE8A33D);
  static const Color accentHover = Color(0xFFF0B45A);
  static const Color accentSoft = Color(0x24E8A33D);
  static const Color ok = Color(0xFF3FB950);
  static const Color warn = Color(0xFFD29922);
  static const Color danger = Color(0xFFF85149);
  static const Color info = Color(0xFF58A6FF);
  static const Color idle = Color(0xFF8B949E);
}

/// 字体栈。字体文件未随包分发（省 2–4MB），运行时走 fontFamilyFallback。
/// 有意的偏差：契约要求 Geist/JetBrains Mono，当前仅声明优先名 + 回退链。
class AppFonts {
  const AppFonts._();
  static const String ui = 'Geist Variable';
  static const String mono = 'JetBrains Mono Variable';
  static const List<String> uiFallback = <String>['-apple-system', 'Segoe UI', 'Noto Sans SC', 'sans-serif'];
  static const List<String> monoFallback = <String>['Menlo', 'Consolas', 'monospace'];
}

/// 间距系统，基准 4px。
class AppSpacing {
  const AppSpacing._();
  static const double unit = 4;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 圆角。
class AppRadius {
  const AppRadius._();
  static const double badge = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double pill = 999;
}

/// 动效：120–200ms ease-out，禁用 bounce/elastic。
class AppMotion {
  const AppMotion._();
  static const Duration short = Duration(milliseconds: 120);
  static const Duration medium = Duration(milliseconds: 200);
  static const Curve easing = Curves.easeOut;
}

/// 触控最小目标（移动端硬指标，DESIGN.md §7）。
const double touchMin = 44;

/// 字阶 10 档（DESIGN.md §3）。供 ThemeData.textTheme 及页面直接引用。
class AppTextStyles {
  const AppTextStyles._();
  static const TextStyle display = TextStyle(fontSize: 30, height: 1.2, fontWeight: FontWeight.w600);
  static const TextStyle h1 = TextStyle(fontSize: 22, height: 1.3, fontWeight: FontWeight.w600);
  static const TextStyle h2 = TextStyle(fontSize: 18, height: 1.35, fontWeight: FontWeight.w600);
  static const TextStyle h3 = TextStyle(fontSize: 15, height: 1.4, fontWeight: FontWeight.w600);
  static const TextStyle body = TextStyle(fontSize: 14, height: 1.5, fontWeight: FontWeight.w400);
  static const TextStyle bodySm = TextStyle(fontSize: 13, height: 1.5, fontWeight: FontWeight.w400);
  static const TextStyle caption = TextStyle(fontSize: 12, height: 1.4, fontWeight: FontWeight.w500);
  static const TextStyle eyebrow = TextStyle(fontSize: 11, height: 1.4, fontWeight: FontWeight.w600, letterSpacing: 0.66);
  static const TextStyle mono = TextStyle(fontSize: 13, height: 1.6, fontWeight: FontWeight.w400, fontFamily: AppFonts.mono, fontFamilyFallback: AppFonts.monoFallback);
  static const TextStyle monoSm = TextStyle(fontSize: 12, height: 1.6, fontWeight: FontWeight.w400, fontFamily: AppFonts.mono, fontFamilyFallback: AppFonts.monoFallback);

  /// 数字等宽对齐（表格/监控/文件大小/时间戳），契约 §3。
  static const TextStyle numeric = TextStyle(
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}
