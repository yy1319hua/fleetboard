import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/system/presentation/panel_upgrade_page.dart';

/// 全屏升级日志的行为：必须**实时跟着刷新**，而且不能把人拽回底部。
///
/// 这两条都是线上反馈出来的：原来的实现把 `lines.join('\n')` 快照塞进 dialog，
/// 打开全屏之后日志就冻住了——升级跑完再回头看，还是点开那一刻的内容。
void main() {
  List<String> makeLines(int n) =>
      List<String>.generate(n, (i) => '==> step $i');

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  testWidgets('日志追加后全屏立即出现新行，并保持停在底部', (tester) async {
    final tail = ValueNotifier<List<String>>(makeLines(80));
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    expect(find.text('升级日志（80 行）'), findsOneWidget);
    expect(find.text('==> step 79'), findsOneWidget);

    // 轮询拿到一批新行
    tail.value = <String>[...tail.value, '==> step 80', '==> step 81'];
    await tester.pumpAndSettle();

    expect(find.text('升级日志（82 行）'), findsOneWidget,
        reason: '行数没变说明全屏没有订阅到新数据');
    expect(find.text('==> step 81'), findsOneWidget, reason: '最后一行没渲染出来');
    expect(positionOf(tester).pixels,
        closeTo(positionOf(tester).maxScrollExtent, 1.0),
        reason: '跟随模式下应停在底部');
  });

  testWidgets('用户在中间往回翻时不抢滚动位置，给出「跳到最新」', (tester) async {
    final tail = ValueNotifier<List<String>>(makeLines(80));
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    // 手指下滑 = 往回看历史
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final held = positionOf(tester).pixels;

    tail.value = <String>[...tail.value, '==> 新的一行'];
    await tester.pumpAndSettle();

    expect(positionOf(tester).pixels, closeTo(held, 1.0),
        reason: '新日志到达不应把用户拽走');
    expect(find.text('跳到最新'), findsOneWidget);

    await tester.tap(find.text('跳到最新'));
    await tester.pumpAndSettle();
    expect(positionOf(tester).pixels,
        closeTo(positionOf(tester).maxScrollExtent, 1.0));
    expect(find.text('跳到最新'), findsNothing);
  });

  testWidgets('没有日志时给空态，不显示空白屏', (tester) async {
    final tail = ValueNotifier<List<String>>(const <String>[]);
    addTearDown(tail.dispose);

    await tester.pumpWidget(MaterialApp(home: LogFullScreen(tail: tail)));
    await tester.pumpAndSettle();

    expect(find.text('暂无日志'), findsOneWidget);
    expect(find.text('升级日志（0 行）'), findsOneWidget);
  });
}
