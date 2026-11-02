import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/monitor/domain/metric_series.dart';
import 'package:app/features/monitor/presentation/server_monitor_tab.dart';

/// 造一条平稳的曲线：数值不重要，只要点够多、能画出来。
List<MetricPoint> _points(int n) {
  final base = DateTime(2026, 11, 3, 4, 0);
  return [
    for (var i = 0; i < n; i++)
      MetricPoint(
        ts: base.add(Duration(minutes: 5 * i)),
        cpuPct: 10 + i.toDouble(),
        memPct: 50,
        diskPct: 13,
        load1: 0.4,
        netInKbps: 0,
        netOutKbps: 0,
      ),
  ];
}

void main() {
  // 回归用例，对应真机现象（2026-11-03 视频）：手指在图上左右拖动时，
  // 外层 TabBarView/PageView 抢走手势，页面滑去隔壁 tab，游标几乎不动。
  //
  // 根因：fl_chart 内置 PanGestureRecognizer（阈值 kPanSlop≈36px），
  // 父级 PageView 是 HorizontalDrag（kTouchSlop≈18px），父级总是先 accept。
  // 修复后图表自己用 HorizontalDrag，靠「内层先收到 move 事件」赢下竞技场。
  //
  // 这个测试就是守住这一点：拖动图表时页面不许翻页，且游标必须有回调。
  testWidgets('在图表上横向拖动时，父级 PageView 不应被拖走', (tester) async {
    final controller = PageController();
    int? cursor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: controller,
            children: [
              MetricChart(
                title: 'CPU',
                unit: '%',
                points: _points(24),
                valueOf: (p) => p.cpuPct,
                fixedMax: 100,
                onCursorChanged: (i) => cursor = i,
              ),
              const Center(child: Text('第二页')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);

    // 关键在于「拖动过程中」页面的位置：等松手再看得不到真相——距离不够
    // PageView 会回弹到 0，反而掩盖了手势被抢走这件事。
    final start = tester.getCenter(chart);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();

    expect(
      controller.position.pixels,
      0,
      reason: '拖动刚开始就被父级 PageView 接管了，页面正在往左滑',
    );
    expect(cursor, isNotNull, reason: '图表没有把手势转换成游标索引');
    expect(cursor, greaterThan(0), reason: '往左拖应落在更靠后的采样点');

    await gesture.moveBy(const Offset(-120, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.page, 0, reason: '松手后页面不应翻到别的 tab');
    expect(
      find.text('第二页'),
      findsNothing,
      reason: '页面被拖走后会露出下一页内容',
    );
  });

  testWidgets('拖动到最左 / 最右时索引被夹在有效范围内', (tester) async {
    final controller = PageController();
    final seen = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: controller,
            children: [
              MetricChart(
                title: 'CPU',
                unit: '%',
                points: _points(10),
                valueOf: (p) => p.cpuPct,
                fixedMax: 100,
                onCursorChanged: (i) {
                  if (i != null) seen.add(i);
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = find.byType(LineChart);
    final rect = tester.getRect(chart);

    // 从左轴外（x 很小）开始拖到屏幕左边缘，再拖到右边缘。
    final gesture = await tester.startGesture(
      Offset(rect.left + 40, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.left - 200, rect.center.dy));
    await gesture.moveTo(Offset(rect.right + 200, rect.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(seen, isNotEmpty);
    expect(seen.every((i) => i >= 0 && i < 10), isTrue,
        reason: '索引越界会把四张图一起带崩：$seen');
    expect(seen.last, 9, reason: '拖到最右应指向最后一个采样点');
    expect(controller.page, 0, reason: '整段拖动都不应翻页');
  });
}
