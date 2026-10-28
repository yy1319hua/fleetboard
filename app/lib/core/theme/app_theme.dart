import 'package:flutter/material.dart';

import '../constants.dart';

/// fleetboard 设计令牌（落地自 web/DESIGN.md 与 M9.1 规格）。
/// 深色「夜间运维控制台」：冷蓝调表面、唯一琥珀强调、语义状态色固定不可挪用。
class AppColors {
  const AppColors._();

  // 表面（Surface）
  static const Color bg = Color(0xFF0F1115); // 页面底（带蓝调近黑，非 #000）
  static const Color s1 = Color(0xFF161A21); // 卡片/面板
  static const Color s2 = Color(0xFF1D222B); // 悬浮层/表头/输入底
  static const Color border = Color(0xFF2A303B); // 1px 分隔线/卡片边框

  // 文字（Text）
  static const Color text = Color(0xFFE6E9EF); // 主文字（暖白，非纯白）
  static const Color muted = Color(0xFF9AA4B2); // 次级说明
  static const Color faint = Color(0xFF6B7480); // 占位/禁用
  static const Color textInverse = Color(0xFF0F1115); // 亮色填充上的文字

  // 唯一强调色（琥珀 accent）——全站只此一个暖色
  static const Color accent = Color(0xFFE8A33D);
  static const Color accentHover = Color(0xFFF0B45A);
  static const Color accentSoft = Color(0x24E8A33D); // rgba(232,163,61,0.14)

  // 语义状态色（固定，不可挪用，只表达状态）
  static const Color ok = Color(0xFF3FB950); // 在线/成功/运行中
  static const Color warn = Color(0xFFE3B341); // 警告/阈值接近
  static const Color danger = Color(0xFFF85149); // 错误/离线/删除
  static const Color info = Color(0xFF58A6FF); // 信息/进行中
  static const Color idle = Color(0xFF6B7480); // 未知/已停止
}

/// 字体（M9.1 仅放常量；字体文件后续引入，M9.2+ 接 Geist Sans / JetBrains Mono）。
///
/// TODO(M9.2): 引入字体文件后于 [ThemeData.fontFamily] = [ui] 与等宽场景接 [mono] 落地；
/// 并设 fontFamilyFallback 回退链（-apple-system, "Segoe UI", "Noto Sans SC", sans-serif）。
class AppFonts {
  const AppFonts._();
  static const String ui = 'Geist Sans';
  static const String mono = 'JetBrains Mono';
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
    onError: Color(0xFFFFFFFF),
    outline: AppColors.border,
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
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    // 底部导航栏沿用令牌：s1 底、accent 选中指示、muted 未选中。
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.s1,
      indicatorColor: AppColors.accentSoft,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    // 卡片 = surface-1 + 1px 边框 + 8px 圆角，无投影、不嵌套。
    cardTheme: CardTheme(
      color: AppColors.s1,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    // 主按钮 = 琥珀底 + 反色字 + 触控高 ≥44 + 圆角 6。
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.textInverse,
        minimumSize: const Size(0, touchMin),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
    ),
  );
}
