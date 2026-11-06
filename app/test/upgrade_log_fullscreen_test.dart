import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/system/presentation/panel_upgrade_page.dart';

/// 升级日志全屏页的回归测试。
///
/// 这些用例对应一个真实 bug：全屏页此前把 lines 拼成一个 `SelectableText`，
/// 等于在打开那一刻拍了张快照，之后来的行一行都不上屏——用户看到的是
/// 「点开全屏就不流式了」。所以第一条用例必须是「新行到达即出现」，
/// 而不是「打开时显示正确」。
void main() {
  testWidgets('新行到达即上屏（不是打开那一刻的快照）', (tester) async {
    final tail = ValueNotifier<List<String>>(<String>['开始下载']);
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    expect(find.text('开始下载'), findsOneWidget);
    expect(find.text('包已下载，开始校验'), findsNothing);

    // 服务端又推进了一步，面板把新尾推进 notifier
    tail.value = <String>['开始下载', '包已下载，开始校验'];
    await tester.pumpAndSettle();

    expect(find.text('包已下载，开始校验'), findsOneWidget);
  });

  testWidgets('用户上翻后，新行不抢走滚动位置，并出现「跳到最新」', (tester) async {
    final tail = ValueNotifier<List<String>>(
      List<String>.generate(200, (i) => 'line $i'),
    );
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;

    // 打开时应在底部（跟着最新一行）
    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThanOrEqualTo(48),
      reason: '初始应贴底',
    );

    // 用手指上翻（jumpTo 走的是同一条 scroll listener，不依赖手势竞技场，
    // SelectionArea 是否吃掉 drag 不会影响这条断言）
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byTooltip('跳到最新'), findsOneWidget);

    // 新行到达：位置必须留在原处
    tail.value = List<String>.generate(205, (i) => 'line $i');
    await tester.pumpAndSettle();

    expect(controller.offset, closeTo(0, 1),
        reason: '用户正在往上读，新行不该把他拽回底部');
  });

  testWidgets('点「跳到最新」后恢复跟随', (tester) async {
    final tail = ValueNotifier<List<String>>(
      List<String>.generate(200, (i) => 'line $i'),
    );
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('跳到最新'));
    await tester.pumpAndSettle();

    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThanOrEqualTo(48),
    );
    // 已经贴底，按钮该消失
    expect(find.byTooltip('跳到最新'), findsNothing);

    // 跟随后新行继续自动上屏
    tail.value = List<String>.generate(210, (i) => 'line $i');
    await tester.pumpAndSettle();
    expect(
      controller.position.maxScrollExtent - controller.offset,
      lessThanOrEqualTo(48),
    );
  });

  testWidgets('没有日志时给空态文案，而不是一片空白', (tester) async {
    final tail = ValueNotifier<List<String>>(const <String>[]);
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有产生日志'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });
}
