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
                    _MetricChart(
                      title: 'CPU',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.cpuPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    _MetricChart(
                      title: '内存',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.memPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    _MetricChart(
                      title: '磁盘',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.diskPct,
                      fixedMax: 100,
                      cursorIndex: _cursorIndex,
                      onCursorChanged: _setCursor,
                    ),
                    _MetricChart(
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

class _MetricChart extends StatelessWidget {
  const _MetricChart({
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (points.isEmpty) {
      return const SizedBox.shrink();
    }
    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), valueOf(points[i])),
    ];
    var maxY = fixedMax ?? spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    if (fixedMax == null) {
      maxY = maxY <= 0 ? 1 : maxY * 1.15;
    }
    // 游标有效时展示该点的值，否则展示最新值；两者共用同一套配色阈值。
    final hasCursor = cursorIndex != null &&
        cursorIndex! >= 0 &&
        cursorIndex! < points.length;
    final activeIndex = hasCursor ? cursorIndex! : points.length - 1;
    final active = points[activeIndex];
    final showingCursor = activeIndex != points.length - 1;
    final color = _colorFor(theme, valueOf(active), fixedMax);

    return Card(
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
                        reservedSize: 34,
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
                  lineTouchData: LineTouchData(
                    // 手指在图上横向移动就更新游标；松手后保留，让用户把数值读完再走。
                    // 落点索引经父级 state 传给其余三张图，实现四图同步。
                    touchCallback: (event, response) {
                      final barSpots = response?.lineBarSpots;
                      if (barSpots == null || barSpots.isEmpty) return;
                      onCursorChanged?.call(barSpots.first.x.round());
                    },
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touched) => [
                        for (final t in touched)
                          LineTooltipItem(
                            '${t.y.toStringAsFixed(1)}$unit\n'
                            '${_hhmm(points[t.x.toInt()].ts)}',
                            TextStyle(
                              color: theme.colorScheme.onInverseSurface,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      color: color,
                      barWidth: 1.6,
                      dotData: const FlDotData(show: false),
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
