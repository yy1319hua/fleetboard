import 'package:flutter/material.dart';

import 'design_tokens.dart';

// 兼容入口：色板 AppColors、字体 AppFonts 历史上从本文件导入（21 处），
// 现在 re-export 生成物，保证引用点不用改、值只有一份。
// 只导出这三类：间距/圆角/动效仍由 core/constants.dart 提供，
// 否则同时 import 两个文件的页面会报 unnecessary_import。
export 'design_tokens.dart'
    show AppColors, AppFonts, AppTextStyles, AppFontSizes;

/// 焦点环：契约 §4 要求 2px 琥珀描边、键盘可见。
/// Flutter 没有全局 focus outline，这里把「聚焦时换 shape.side」抽成共享构造器，
/// 供各类按钮主题复用，避免每处各写一遍。
WidgetStateProperty<OutlinedBorder> _focusableShape(
  double radius, {
  BorderSide baseSide = BorderSide.none,
}) {
  return WidgetStateProperty.resolveWith<OutlinedBorder>((states) {
    final focused = states.contains(WidgetState.focused);
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: focused
          ? const BorderSide(color: AppColors.accent, width: 2)
          : baseSide,
    );
  });
}

/// 卡片形状：标准圆角矩形 + 顶部 1px 亮线（border-hi）。
///
/// 深色下四周边框对比仅 1.68:1，卡片与背景仍偏近；顶边加一条更亮的实色线，
/// 相当于受光边缘，把卡片从背景里"托"出来一档。
/// 只画线——不加投影、不加渐变、不加外发光（DESIGN.md 第 6 节）。
/// 落在 CardTheme.shape 上，28 处 Card(...) 自动生效，无需逐页改。
class AppCardBorder extends RoundedRectangleBorder {
  const AppCardBorder({
    super.side,
    super.borderRadius,
    this.highlight = AppColors.borderHi,
  });

  final Color highlight;

  @override
  ShapeBorder scale(double t) => AppCardBorder(
        side: side.scale(t),
        borderRadius: borderRadius * t,
        highlight: highlight,
      );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    super.paint(canvas, rect, textDirection: textDirection);
    final r = borderRadius.resolve(textDirection);
    // 两端内缩圆角半径，避免亮线在圆角处探出卡片轮廓。
    final y = rect.top + 0.5;
    canvas.drawLine(
      Offset(rect.left + r.topLeft.x, y),
      Offset(rect.right - r.topRight.x, y),
      Paint()
        ..color = highlight
        ..strokeWidth = 1,
    );
  }
}

/// 字阶 10 档落到 Material TextTheme（契约 §3 / 方案 §5.2）。
///
/// 关键：不能从零 new 一个 TextTheme —— 现有页面大量使用 titleSmall / labelLarge
/// 等未纳入契约的角色，置空会让它们退化成默认大字或抛错。这里以 M3 默认字阶为
/// 基线，只覆盖契约定义的 8 个角色，再用 apply() 把字体回退链和文字色套到全部角色。
TextTheme _buildTextTheme() {
  final base = ThemeData.dark(useMaterial3: true).textTheme;
  return base
      .copyWith(
        displaySmall: AppTextStyles.display,
        headlineMedium: AppTextStyles.h1,
        titleLarge: AppTextStyles.h2,
        titleMedium: AppTextStyles.h3,
        bodyLarge: AppTextStyles.body,
        bodyMedium: AppTextStyles.bodySm,
        bodySmall: AppTextStyles.caption,
        labelSmall: AppTextStyles.eyebrow,
      )
      .apply(
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
        bodyColor: AppColors.text,
        displayColor: AppColors.text,
      );
}

/// 由令牌派生 Material 3 主题：深色为主、不留投影、不嵌套卡片、圆角克制。
ThemeData buildAppTheme() {
  const colorScheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.textInverse,
    secondary: AppColors.accent,
    onSecondary: AppColors.textInverse,
    surface: AppColors.s1,
    onSurface: AppColors.text,
    error: AppColors.danger,
    onError: AppColors.text,
    outline: AppColors.border,
    outlineVariant: AppColors.borderStrong,
    surfaceContainerHighest: AppColors.s2,
    onSurfaceVariant: AppColors.muted,
    inverseSurface: AppColors.s2,
    onInverseSurface: AppColors.text,
    inversePrimary: AppColors.accentHover,
    shadow: Colors.transparent, // 深色不投影（DESIGN.md §6）
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.bg,
    // 字体文件未随包分发：声明优先字体名 + 显式回退链，将来打包字体即可直接生效。
    fontFamily: AppFonts.ui,
    fontFamilyFallback: AppFonts.uiFallback,
    textTheme: _buildTextTheme(),
    focusColor: AppColors.accentSoft,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.s1,
      indicatorColor: AppColors.accentSoft,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    // 卡片：surface-1 + 1px 边框 + 顶部 1px 亮线（border-hi），无投影、不嵌套。
    // 28 处 Card(...) 全部走 cardTheme，一处改即全端生效。
    cardTheme: CardTheme(
      color: AppColors.s1,
      elevation: 0,
      shape: AppCardBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    // 主按钮 = 琥珀底 + 反色字 + 触控高 ≥44 + 圆角 6 + 聚焦 2px 琥珀环。
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(AppColors.accent),
        foregroundColor: WidgetStateProperty.all(AppColors.textInverse),
        minimumSize: WidgetStateProperty.all(const Size(0, touchMin)),
        shape: _focusableShape(AppRadius.sm),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStateProperty.all(const Size(0, touchMin)),
        shape: _focusableShape(AppRadius.sm),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(AppColors.text),
        minimumSize: WidgetStateProperty.all(const Size(0, touchMin)),
        shape: _focusableShape(
          AppRadius.sm,
          baseSide: const BorderSide(color: AppColors.border),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(AppColors.accent),
        minimumSize: WidgetStateProperty.all(const Size(0, touchMin)),
        shape: _focusableShape(AppRadius.sm),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(AppColors.muted),
        minimumSize: WidgetStateProperty.all(const Size(touchMin, touchMin)),
        shape: _focusableShape(AppRadius.sm),
      ),
    ),
    // 输入：surface-2 底、1px border、圆角 6、聚焦换成 2px 琥珀。
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.s2,
      hintStyle: AppTextStyles.bodySm.copyWith(color: AppColors.faint),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.muted,
      textColor: AppColors.text,
      minVerticalPadding: AppSpacing.sm,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.s2,
      contentTextStyle: AppTextStyles.bodySm.copyWith(color: AppColors.text),
      actionTextColor: AppColors.accent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: const BorderSide(color: AppColors.borderStrong),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.s2,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderStrong),
      ),
      textStyle: AppTextStyles.caption.copyWith(color: AppColors.text),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
    ),
  );
}
