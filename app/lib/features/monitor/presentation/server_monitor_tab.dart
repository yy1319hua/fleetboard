import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/async_state_view.dart';
import '../application/metrics_notifier.dart';
import '../domain/metric_series.dart';

/// 服务器详情 · 监控段。
///
/// 四个指标分四张图而不是叠在一张里：手机竖屏宽度约 360dp，四条线叠在一起
/// 会互相遮挡，且 CPU 与「网络 KB/s」量纲差两个数量级，共用 Y 轴毫无意义。
class ServerMonitorTab extends ConsumerStatefulWidget {
  const ServerMonitorTab({super.key, required this.serverId});
  final int serverId;

  @override
  ConsumerState<ServerMonitorTab> createState() => _ServerMonitorTabState();
}

class _ServerMonitorTabState extends ConsumerState<ServerMonitorTab> {
  MetricRange _range = MetricRange.day;

  /// 游标索引：手指在任意一张图上左右拖动时记录，四张图共用同一个值，
  /// 这样「同一时刻的 CPU / 内存 / 磁盘 / 负载」能一起读，而不是各看各的。
  /// null 表示没有游标，各图显示最新值。
  int? _cursorIndex;

  void _setCursor(int? index) {
    // 拖动时每帧都会回调，索引没变就不重建——否则四张图每次触摸移动都重绘一遍。
    if (_cursorIndex == index) return;
    setState(() => _cursorIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final key = (serverId: widget.serverId, range: _range);
    final state = ref.watch(metricsProvider(key));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              SegmentedButton<MetricRange>(
                segments: [
                  for (final r in MetricRange.values)
                    ButtonSegment<MetricRange>(value: r, label: Text(r.label)),
                ],
                selected: {_range},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() {
                  _range = v.first;
                  _cursorIndex = null; // 换时间窗后旧索引没有意义
                }),
              ),
              const Spacer(),
              if (state is AsyncData<MetricSeries>)
                Text(
                  '每点 ${_stepLabel(state.value.stepSec)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        Expanded(
          child: AsyncStateView<MetricSeries>(
            value: state,
            emptyHint: '这个时间窗内还没有采样。面板每分钟采一次，'
                '纳管后约一分钟才会出现第一条。',
            onRetry: () => ref.read(metricsProvider(key).notifier).load(),
            builder: (series) {
              final points = downsample(series.points);
              return RefreshIndicator(
                onRefresh: () =>
                    ref.read(metricsProvider(key).notifier).refresh(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(
                        '在任意一张图上左右拖动，四张图会同步定位到同一时刻。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ),
                    MetricChart(
                      title: 'CPU',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.cpuPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    MetricChart(
                      title: '内存',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.memPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    MetricChart(
                      title: '磁盘',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.diskPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    MetricChart(
                      title: '负载（1 分钟）',
                      unit: '',
                      points: points,
                      valueOf: (p) => p.load1,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _stepLabel(int sec) {
    if (sec <= 0) return '—';
    if (sec < 60) return '${sec}s';
    if (sec % 3600 == 0) return '${sec ~/ 3600}h';
    return '${sec ~/ 60}min';
  }
}

class MetricChart extends StatefulWidget {
  const MetricChart({
    super.key,
    required this.title,
    required this.unit,
    required this.points,
    required this.valueOf,
    this.fixedMax,
    this.cursorIndex,
    this.onCursorChanged,
  });

  final String title;
  final String unit;
  final List<MetricPoint> points;
  final double Function(MetricPoint) valueOf;

  /// 百分比类固定 0–100；负载类按数据自适应。
  final double? fixedMax;

  /// 四张图共用的游标索引（由父级持有，实现联动）。
  final int? cursorIndex;

  /// 拖动回调：把落点索引回传给父级。为 null 表示这张图不响应拖动。
  final ValueChanged<int?>? onCursorChanged;

  /// 左轴文字占位宽度。必须与 [leftTitles] 的 `reservedSize` 一致，
  /// 否则手指位置换算成索引时会整体偏移。
  static const double _yAxisWidth = 34;

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart> {
  /// 绘图区的 key。手指可能落在卡片任意位置（标题、数值行、图上），
  /// 统一拿这块 RenderBox 把全局坐标换算成绘图区内的横向比例。
  final GlobalKey _plotKey = GlobalKey();

  /// 把一次指针位置换算成采样点索引。
  ///
  /// 用 [Listener] 而不是 GestureDetector/RawGestureDetector：Listener 收的是
  /// 原始 pointer 事件，不参与手势竞技场，父级 TabBarView 无论赢不赢都抢不走它。
  /// v0.4.10 试过在内层塞 HorizontalDragGestureRecognizer 去竞技场里抢，
  /// 自动化测试能赢、真机仍然被外层拿走，说明「谁先 accept」在真机上不可靠。
  void _emitAt(Offset globalPosition, int count) {
    final box = _plotKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || count < 2) return;
    final plotWidth = box.size.width - MetricChart._yAxisWidth;
    if (plotWidth <= 0) return;
    final local = box.globalToLocal(globalPosition);
    final ratio = (local.dx - MetricChart._yAxisWidth) / plotWidth;
    widget.onCursorChanged?.call((ratio.clamp(0.0, 1.0) * (count - 1)).round());
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final unit = widget.unit;
    final points = widget.points;
    final valueOf = widget.valueOf;
    final fixedMax = widget.fixedMax;
    final cursorIndex = widget.cursorIndex;
    final theme = Theme.of(context);
    if (points.isEmpty) {
      return const SizedBox.shrink();
    }
    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), valueOf(points[i])),
    ];
    var maxY =
        fixedMax ?? spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    if (fixedMax == null) {
      maxY = maxY <= 0 ? 1 : maxY * 1.15;
    }
    // 游标有效时展示该点的值，否则展示最新值；两者共用同一套配色阈值。
    final ci = cursorIndex;
    final hasCursor = ci != null && ci >= 0 && ci < points.length;
    final activeIndex = hasCursor ? ci : points.length - 1;
    final active = points[activeIndex];
    final showingCursor = activeIndex != points.length - 1;
    final color = _colorFor(theme, valueOf(active), fixedMax);

    return Listener(
      // 整张卡片都能拖：绘图区只有 130 高，只认图上触摸会显得「滑不动」。
      // Listener 收原始指针事件，不进手势竞技场，父级 TabBarView 抢不走。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _emitAt(e.position, points.length),
      onPointerMove: (e) => _emitAt(e.position, points.length),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (showingCursor) ...[
                    Text(
                      _hhmm(active.ts),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '${valueOf(active).toStringAsFixed(1)}$unit',
                    style: theme.textTheme.titleSmall?.copyWith(color: color),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                key: _plotKey,
                height: 130,
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: (spots.length - 1).toDouble(),
                    minY: 0,
                    maxY: maxY,
                    clipData: const FlClipData.all(),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      horizontalInterval: fixedMax == null ? null : 25,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: theme.colorScheme.outlineVariant,
                        strokeWidth: 0.5,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    // 游标：一条虚线竖线，四张图因共用 cursorIndex 而同步出现。
                    extraLinesData: showingCursor
                        ? ExtraLinesData(
                            verticalLines: [
                              VerticalLine(
                                x: activeIndex.toDouble(),
                                color: theme.colorScheme.outline,
                                strokeWidth: 1,
                                dashArray: const [3, 3],
                              ),
                            ],
                          )
                        : const ExtraLinesData(),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: MetricChart._yAxisWidth,
                          interval: fixedMax == null ? null : 50,
                          getTitlesWidget: (value, meta) => Text(
                            '${value.toInt()}$unit',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          interval: _bottomInterval(points.length),
                          getTitlesWidget: (value, meta) {
                            final i = value.round();
                            if (i < 0 || i >= points.length) {
                              return const SizedBox.shrink();
                            }
                            final t = points[i].ts;
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${t.hour.toString().padLeft(2, '0')}:'
                                '${t.minute.toString().padLeft(2, '0')}',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontSize: 10),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    // 手势由外层 RawGestureDetector 统一接管；这里必须关掉内置
                    // touch，否则 fl_chart 的 PanGestureRecognizer 会再进一次竞技场，
                    // 且它自带的 tooltip 会跟着手指飘、盖住曲线。
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: false,
                        color: color,
                        barWidth: 1.6,
                        dotData: FlDotData(
                          // 游标落点画一个点：线只有 1.6 宽，光靠虚线看不出
                          // 到底落在哪个采样上。
                          show: showingCursor,
                          checkToShowDot: (spot, _) =>
                              spot.x.round() == activeIndex,
                          getDotPainter: (spot, xPct, bar, index) =>
                              FlDotCirclePainter(
                            radius: 3,
                            color: color,
                            strokeWidth: 0,
                            strokeColor: Colors.transparent,
                          ),
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          color: color.withAlpha(30),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static double _bottomInterval(int count) {
    if (count <= 6) return 1;
    return (count / 5).ceilToDouble();
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// 百分比指标 80% 起转黄、90% 起转红；负载类保持主题色（无绝对阈值）。
  static Color _colorFor(ThemeData theme, double v, double? fixedMax) {
    if (fixedMax == null) return theme.colorScheme.primary;
    if (v >= 90) return theme.colorScheme.error;
    if (v >= 80) return const Color(0xFFB26A00);
    return theme.colorScheme.primary;
  }
}
