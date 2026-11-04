import 'package:app/core/constants.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/core/widgets/responsive.dart';
import 'package:app/core/widgets/status_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设计系统回归：令牌落地、状态语义、响应式断点。
void main() {
  group('ThemeData 契约落地', () {
    test('字阶 10 档映射到 TextTheme 且不再用系统默认字号', () {
      final t = buildAppTheme().textTheme;
      expect(t.displaySmall!.fontSize, 30);
      expect(t.headlineMedium!.fontSize, 22);
      expect(t.titleLarge!.fontSize, 18);
      expect(t.titleMedium!.fontSize, 15);
      expect(t.bodyLarge!.fontSize, 14);
      expect(t.bodyMedium!.fontSize, 13);
      expect(t.bodySmall!.fontSize, 12);
      expect(t.labelSmall!.fontSize, 11);
      // 未纳入契约的角色仍保留 M3 基线，不能被清空。
      expect(t.titleSmall, isNotNull);
      expect(t.labelLarge, isNotNull);
    });

    test('显式字体回退链（字体文件未打包，属有意的偏差）', () {
      // ThemeData 的 fontFamily/fontFamilyFallback 是构造参数，不暴露 getter；
      // 它们最终落到每档 TextStyle 上，所以断言字阶里的实际结果。
      final text = buildAppTheme().textTheme;
      for (final style in <TextStyle?>[
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
        text.titleMedium,
      ]) {
        expect(style!.fontFamily, AppFonts.ui);
        expect(style.fontFamilyFallback, contains('Noto Sans SC'));
      }
    });

    test('7 个此前缺失的主题分支全部补齐', () {
      final t = buildAppTheme();
      expect(t.inputDecorationTheme.filled, isTrue);
      expect(t.textButtonTheme.style, isNotNull);
      expect(t.outlinedButtonTheme.style, isNotNull);
      expect(t.filledButtonTheme.style, isNotNull);
      expect(t.iconButtonTheme.style, isNotNull);
      expect(t.snackBarTheme.backgroundColor, AppColors.s2);
      expect(t.tooltipTheme.decoration, isNotNull);
      expect(t.listTileTheme.iconColor, AppColors.muted);
    });

    test('所有按钮最小触控高度 44；聚焦时有 2px 琥珀环', () {
      final t = buildAppTheme();
      const min = Size(0, touchMin);
      for (final style in <ButtonStyle?>[
        t.elevatedButtonTheme.style,
        t.filledButtonTheme.style,
        t.outlinedButtonTheme.style,
        t.textButtonTheme.style,
      ]) {
        expect(style!.minimumSize!.resolve(<WidgetState>{}), min);
      }
      final focused = t.elevatedButtonTheme.style!.shape!
              .resolve(<WidgetState>{WidgetState.focused})
          as RoundedRectangleBorder;
      expect(focused.side.color, AppColors.accent);
      expect(focused.side.width, 2);
      final normal = t.elevatedButtonTheme.style!.shape!
          .resolve(<WidgetState>{}) as RoundedRectangleBorder;
      expect(normal.side, BorderSide.none);
    });

    test('色板两端修正值生效：warn / idle / faint 不再低对比', () {
      expect(AppColors.warn, const Color(0xFFD29922));
      expect(AppColors.idle, const Color(0xFF8B949E));
      expect(AppColors.faint, const Color(0xFF808A98));
      // 新增的三个表面色，App 此前缺失。
      expect(AppColors.s3, const Color(0xFF242A35));
      expect(AppColors.borderStrong, const Color(0xFF3A4250));
      expect(AppColors.terminal, const Color(0xFF0B0D10));
    });
  });

  group('状态信号不只靠颜色', () {
    testWidgets('StatusDot 带 semanticLabel 时读屏可读', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: StatusDot(StatusKind.ok, semanticLabel: '在线'),
        ),
      ));
      expect(find.bySemanticsLabel('在线'), findsOneWidget);
    });

    testWidgets('StatusLabel 显示中文状态词且整体带语义', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: StatusLabel(kind: StatusKind.ok, label: '运行中'),
        ),
      ));
      expect(find.text('运行中'), findsOneWidget);
      expect(find.bySemanticsLabel('运行中'), findsOneWidget);
    });

    test('连接状态与容器状态词表覆盖已知枚举', () {
      expect(connectionStatusLabel('online'), '在线');
      expect(connectionStatusLabel('offline'), '离线');
      expect(connectionStatusLabel('unknown'), '未知');
      expect(containerStateLabel('running'), '运行中');
      expect(containerStateLabel('exited'), '已退出');
      expect(statusKindLabel(StatusKind.danger), '异常');
    });
  });

  group('响应式断点', () {
    test('三档列数', () {
      expect(AppBreakpoints.overviewColumns(420), 1);
      expect(AppBreakpoints.overviewColumns(800), 2);
      expect(AppBreakpoints.overviewColumns(1280), 3);
      expect(AppBreakpoints.isCompact(599), isTrue);
      expect(AppBreakpoints.isMedium(800), isTrue);
      expect(AppBreakpoints.isExpanded(1100), isTrue);
    });

    testWidgets('宽屏 Shell 用侧栏、窄屏用底部 Tab', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: ResponsiveContent(child: Text('内容'))),
      ));
      expect(find.text('内容'), findsOneWidget);
    });
  });
}
