import 'package:flutter/material.dart';

/// 间距系统：基准 4px（DESIGN.md 间距基准）；不做投影、不嵌套卡片。
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

/// 圆角：按钮/输入 6，卡片 8（DESIGN.md）。
class AppRadius {
  const AppRadius._();
  static const double sm = 6;
  static const double md = 8;
}

/// 动效：120–200ms ease-out，禁用 bounce/elastic（DESIGN.md 护栏）。
class AppMotion {
  const AppMotion._();
  static const Duration short = Duration(milliseconds: 120);
  static const Duration medium = Duration(milliseconds: 200);
  static const Curve easing = Curves.easeOut;
}

/// 触控最小目标 44×44（移动端硬指标，DESIGN.md §7）。
const double touchMin = 44;
