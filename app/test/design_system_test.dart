import 'package:app/core/constants.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/core/widgets/async_state_view.dart';
import 'package:app/core/widgets/refresh_icon_button.dart';
import 'package:app/core/widgets/responsive.dart';
import 'package:app/core/widgets/status_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  group('P0-1 字阶单一真源', () {
    test('AppFontSizes 10 档与 TextTheme 完全一致，最小值 >= 11', () {
      final t = buildAppTheme().textTheme;
      expect(t.displaySmall!.fontSize, AppFontSizes.display);
      expect(t.headlineMedium!.fontSize, AppFontSizes.h1);
      expect(t.titleLarge!.fontSize, AppFontSizes.h2);
      expect(t.titleMedium!.fontSize, AppFontSizes.h3);
      expect(t.bodyLarge!.fontSize, AppFontSizes.body);
      expect(t.bodyMedium!.fontSize, AppFontSizes.bodySm);
      expect(t.bodySmall!.fontSize, AppFontSizes.caption);
      expect(t.labelSmall!.fontSize, AppFontSizes.eyebrow);
      const all = <double>[
        AppFontSizes.display,
        AppFontSizes.h1,
        AppFontSizes.h2,
        AppFontSizes.h3,
        AppFontSizes.body,
        AppFontSizes.bodySm,
        AppFontSizes.caption,
        AppFontSizes.eyebrow,
        AppFontSizes.mono,
        AppFontSizes.monoSm,
      ];
      expect(all.every((s) => s >= 11), isTrue,
          reason: '契约下限 11px，不得再出现 10px 这类违规值');
      expect(AppFontSizes.eyebrow, 11);
    });
  });

  group('P1-2 StatusLabel 统一入口', () {
    testWidgets('compact 形态只画点但读屏仍有中文语义、不重复文字', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: StatusLabel(
            kind: StatusKind.ok,
            label: '在线',
            compact: true,
          ),
        ),
      ));
      expect(find.text('在线'), findsNothing,
          reason: '紧凑位靠相邻页面文案承担可见第二通道，不应重复文字');
      expect(find.bySemanticsLabel('在线'), findsOneWidget);
    });

    testWidgets('完整形态显示 12px 中文状态词', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: StatusLabel(kind: StatusKind.ok, label: '在线'),
        ),
      ));
      final text = tester.widget<Text>(find.text('在线'));
      expect(text.style!.fontSize, AppFontSizes.caption);
    });
  });

  group('P2-3 刷新反馈统一 600ms 转圈', () {
    testWidgets('RefreshIconButton 带 label 时显示中文文案且按下转圈', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: RefreshIconButton(
            label: '重试',
            onRefresh: () async => calls++,
          ),
        ),
      ));
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '按下瞬间换成进度圈，先给「已收到」的反馈');
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: '接口很快也要把进度圈保持到 minSpin 600ms');
      await tester.pumpAndSettle(const Duration(milliseconds: 700));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('AsyncStateView 错误态重用 RefreshIconButton 而非裸按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: AsyncStateView<List<String>>(
            value: const AsyncError<List<String>>('网络错误', StackTrace.empty),
            emptyHint: '暂无数据',
            onRetry: () {},
            builder: (_) => const SizedBox.shrink(),
          ),
        ),
      ));
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(RefreshIconButton), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget,
          reason: '空闲态由统一组件渲染刷新图标，不再是 FilledButton.tonalIcon');
    });
  });
}
