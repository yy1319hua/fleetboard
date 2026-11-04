import 'package:flutter/material.dart';

/// 响应式断点（DESIGN.md §8）。App 与 Web 用同一组数值。
abstract final class AppBreakpoints {
  const AppBreakpoints._();

  /// < 600：单列 + 底部 Tab。
  static const double compact = 600;

  /// 600–1024：双栏（列表两列）。
  static const double medium = 1024;

  /// ≥ 1024：侧栏 + 内容区；内容最大宽 1440。
  static const double expanded = 1280;

  /// Web 桌面左栏起点（md = 768）。
  static const double webSidebar = 768;

  /// 内容区最大宽度（DESIGN.md §5 栅格）。
  static const double contentMax = 1440;

  static bool isCompact(double width) => width < compact;
  static bool isMedium(double width) => width >= compact && width < medium;
  static bool isExpanded(double width) => width >= medium;

  /// 概览页服务器卡片的列数。
  static int overviewColumns(double width) {
    if (width >= medium) return 3;
    if (width >= compact) return 2;
    return 1;
  }
}

/// 内容区最大宽度约束：宽屏时不让表格/列表拉到 2K 屏两端。
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.maxWidth = AppBreakpoints.contentMax,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
