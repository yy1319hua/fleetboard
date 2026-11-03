import 'dart:async';

import 'package:app/core/widgets/refresh_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 刷新按钮的存在意义就是「让用户看出按下去生效了」，所以这里测的都是观感：
/// 反馈是不是立刻出现、会不会一闪而过、连点会不会打出一串请求。
void main() {
  Widget host({
    required Future<void> Function() onRefresh,
    String tooltip = '刷新',
  }) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: <Widget>[
            RefreshIconButton(onRefresh: onRefresh, tooltip: tooltip),
          ],
        ),
      ),
    );
  }

  /// 进度圈在 AnimatedSwitcher 里有 150ms 过渡，等它稳定下来再断言，
  /// 否则新旧两个 child 会同时在树上。
  Future<void> settleSwitch(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 200));

  testWidgets('按下立刻出现进度圈，不等接口返回', (tester) async {
    final completer = Completer<void>();
    await tester.pumpWidget(host(onRefresh: () => completer.future));

    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.byType(RefreshIconButton));
    await tester.pump();
    await settleSwitch(tester);

    // 接口还挂着，进度圈已经在转——这就是「按下有反应」。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('接口秒回也要转满最短时长，不会一闪而过', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(onRefresh: () async => calls++));

    await tester.tap(find.byType(RefreshIconButton));
    await tester.pump();
    await settleSwitch(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 合计 400ms：接口早已返回，但进度圈必须还在。
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 越过 600ms 之后才恢复。
    await tester.pump(const Duration(milliseconds: 400));
    await settleSwitch(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls, 1);
  });

  testWidgets('刷新中连点不会重复触发', (tester) async {
    final completer = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(host(onRefresh: () {
      calls++;
      return completer.future;
    }));

    await tester.tap(find.byType(RefreshIconButton));
    await tester.pump();
    await settleSwitch(tester);

    await tester.tap(find.byType(RefreshIconButton), warnIfMissed: false);
    await tester.tap(find.byType(RefreshIconButton), warnIfMissed: false);
    await tester.pump();

    expect(calls, 1);

    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('刷新失败时按钮也能恢复，不会永远转圈', (tester) async {
    await tester.pumpWidget(host(
      onRefresh: () async => throw StateError('ssh 断了'),
    ));

    await tester.tap(find.byType(RefreshIconButton));
    await tester.pump();
    await settleSwitch(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    await settleSwitch(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('刷新中提示文字改为「正在刷新…」', (tester) async {
    final completer = Completer<void>();
    await tester.pumpWidget(host(onRefresh: () => completer.future));

    expect(
      find.byTooltip('刷新'),
      findsOneWidget,
    );

    await tester.tap(find.byType(RefreshIconButton));
    await tester.pump();
    await settleSwitch(tester);

    expect(find.byTooltip('正在刷新…'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
  });
}
