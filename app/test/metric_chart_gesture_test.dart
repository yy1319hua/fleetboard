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
  // 回归用例，对应真机现象（2026-11-03 两次验收失败）：
  // 手指在图上左右拖动时，外层 TabBarView 抢走手势，页面滑去隔壁段，
  // 游标几乎不动。v0.4.10 用 RawGestureDetector 在内层抢竞技场，
  // 自动化测试能赢、真机仍然被外层拿走，所以 v0.4.11 改成两件事：
  //   1. 监控段给 TabBarView 传 NeverScrollableScrollPhysics，外层不参战；
  //   2. 图表用 Listener 收原始指针事件，根本不进竞技场。
  // 这条用例把两者一起守住：游标必须跟手，页面不许换段。
  testWidgets('监控段禁止横滑时，拖卡片能移动游标且不换段', (tester) async {
    final controller = TabController(length: 5, vsync: const TestVSync());
    int? cursor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            bottom: TabBar(
              controller: controller,
              tabs: const [
                Tab(text: '概览'),
                Tab(text: '容器'),
                Tab(text: '监控'),
                Tab(text: '文件'),
                Tab(text: '运维'),
              ],
            ),
          ),
          body: TabBarView(
            controller: controller,
            // 与 server_detail_page 里监控段的取值保持一致。
            physics: const NeverScrollableScrollPhysics(),
            children: [
              const Center(child: Text('概览页')),
              const Center(child: Text('容器页')),
              ListView(
                children: [
                  MetricChart(
                    title: 'CPU',
                    unit: '%',
                    points: _points(24),
                    valueOf: (p) => p.cpuPct,
                    fixedMax: 100,
                    onCursorChanged: (i) => cursor = i,
                  ),
                ],
              ),
              const Center(child: Text('文件页')),
              const Center(child: Text('运维页')),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('监控'));
    await tester.pumpAndSettle();
    expect(controller.index, 2);

    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);

    final start = tester.getCenter(chart);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();

    expect(controller.index, 2, reason: '监控段不该被横滑换走');
    expect(cursor, isNotNull, reason: '图表没有把手势转换成游标索引');
    expect(cursor, greaterThan(0), reason: '往左拖应落在更靠后的采样点');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.index, 2, reason: '松手后也不该换段');
  });

  testWidgets('手指落在卡片标题上也能定位（Listener 覆盖整卡）', (tester) async {
    int? cursor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              MetricChart(
                title: 'CPU',
                unit: '%',
                points: _points(24),
                valueOf: (p) => p.cpuPct,
                fixedMax: 100,
                onCursorChanged: (i) => cursor = i,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题行在绘图区上方，旧实现只把 recognizer 挂在图上，这里点不动。
    final title = find.text('CPU');
    await tester.tapAt(tester.getCenter(title));
    await tester.pump();

    expect(cursor, isNotNull, reason: '标题区域也应能定位游标');
  });

  testWidgets('physics 切到 NeverScrollable 后，点 Tab 仍能正常换段', (tester) async {
    // 禁的只是「手指横滑」，不是「换段」本身：TabBar 点击走的是
    // TabController.animateTo → PageController.animateToPage，程序化滚动
    // 不受 physics 限制。这条守住这一点，别把监控段做成死胡同。
    final controller = TabController(length: 5, vsync: const TestVSync());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabBarView(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            children: const [
              Center(child: Text('概览页')),
              Center(child: Text('容器页')),
              Center(child: Text('监控页')),
              Center(child: Text('文件页')),
              Center(child: Text('运维页')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.animateTo(2);
    await tester.pumpAndSettle();
    expect(controller.index, 2);
    expect(find.text('监控页'), findsOneWidget);

    controller.animateTo(3);
    await tester.pumpAndSettle();
    expect(controller.index, 3);
    expect(find.text('文件页'), findsOneWidget);
  });

  testWidgets('拖动到最左 / 最右时索引被夹在有效范围内', (tester) async {
    final seen = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
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

    final gesture = await tester.startGesture(
      Offset(rect.left + 40, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.left - 200, rect.center.dy));
    await gesture.moveTo(Offset(rect.right + 200, rect.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(seen, isNotEmpty);
    expect(
      seen.every((i) => i >= 0 && i < 10),
      isTrue,
      reason: '索引越界会把四张图一起带崩：$seen',
    );
    expect(seen.last, 9, reason: '拖到最右应指向最后一个采样点');
  });
}
