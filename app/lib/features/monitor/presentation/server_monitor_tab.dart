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
                onSelectionChanged: (v) => setState(() => _range = v.first),
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
                    _MetricChart(
                      title: 'CPU',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.cpuPct,
                      fixedMax: 100,
                    ),
                    _MetricChart(
                      title: '内存',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.memPct,
                      fixedMax: 100,
                    ),
                    _MetricChart(
                      title: '磁盘',
                      unit: '%',
                      points: points,
                      valueOf: (p) => p.diskPct,
                      fixedMax: 100,
                    ),
                    _MetricChart(
                      title: '负载（1 分钟）',
                      unit: '',
                      points: points,
                      valueOf: (p) => p.load1,
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
  });

  final String title;
  final String unit;
  final List<MetricPoint> points;
  final double Function(MetricPoint) valueOf;

  /// 百分比类固定 0–100；负载类按数据自适应。
  final double? fixedMax;

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
    final color = _colorFor(theme, valueOf(points.last), fixedMax);

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
                Text(
                  '${valueOf(points.last).toStringAsFixed(1)}$unit',
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
