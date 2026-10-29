/// 时序指标点（对齐后端 model.ServerMetric 的 JSON）。
///
/// 后端 `/api/servers/:id/metrics` 的 data 形如：
/// `{range, step_sec, count, points: [...]}`，其中 points 是**已分桶**的采样
/// （24h→5 分钟桶约 288 点，7d→30 分钟桶约 336 点）。客户端不再假设原始粒度。
class MetricPoint {
  const MetricPoint({
    required this.ts,
    required this.cpuPct,
    required this.memPct,
    required this.diskPct,
    required this.load1,
    required this.netInKbps,
    required this.netOutKbps,
  });

  final DateTime ts;
  final double cpuPct;
  final double memPct;
  final double diskPct;
  final double load1;
  final double netInKbps;
  final double netOutKbps;

  factory MetricPoint.fromJson(Map<String, dynamic> json) {
    double d(String key) {
      final v = json[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    final rawTs = json['ts'];
    DateTime ts;
    if (rawTs is String) {
      ts = DateTime.tryParse(rawTs)?.toLocal() ?? DateTime.now();
    } else {
      ts = DateTime.now();
    }
    return MetricPoint(
      ts: ts,
      cpuPct: d('cpu_pct'),
      memPct: d('mem_pct'),
      diskPct: d('disk_pct'),
      load1: d('load1'),
      netInKbps: d('net_in_kbps'),
      netOutKbps: d('net_out_kbps'),
    );
  }
}

/// 一次查询的结果集（含服务端实际使用的桶宽，供 UI 说明「每点代表多久」）。
class MetricSeries {
  const MetricSeries({
    required this.range,
    required this.stepSec,
    required this.points,
  });

  final String range;
  final int stepSec;
  final List<MetricPoint> points;

  bool get isEmpty => points.isEmpty;
}

/// min-max 抽稀：把任意长度序列压到至多 [maxPoints] 个点，**保留极值**。
///
/// 为什么不用「等间隔取样」：等间隔会直接跳过尖峰，而运维场景里恰恰只关心尖峰
/// （CPU 突然打满、网络抖动）。min-max 按桶取每桶的最小和最大值，
/// 曲线形状与真实包络一致，代价是点数约为 2×桶数。
///
/// 抽稀失败（maxPoints 过小）时退化到等间隔，保证一定返回可绘制序列。
List<MetricPoint> downsample(
  List<MetricPoint> points, {
  int maxPoints = 500,
}) {
  if (points.length <= maxPoints) return points;
  final buckets = maxPoints ~/ 2;
  if (buckets < 2) {
    final step = (points.length / maxPoints).ceil();
    return [
      for (var i = 0; i < points.length; i += step) points[i],
    ];
  }
  final bucketSize = (points.length / buckets).ceil();
  final out = <MetricPoint>[];
  for (var start = 0; start < points.length; start += bucketSize) {
    final end = (start + bucketSize).clamp(0, points.length);
    var lo = points[start];
    var hi = points[start];
    for (var i = start; i < end; i++) {
      final p = points[i];
      if (p.cpuPct < lo.cpuPct) lo = p;
      if (p.cpuPct > hi.cpuPct) hi = p;
    }
    out.add(lo);
    if (!identical(lo, hi)) out.add(hi);
  }
  return out;
}
