import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/metrics_repository.dart';
import '../domain/metric_series.dart';

/// 监控时间窗。**只有这两个**：后端 `range` 仅接受 24h / 7d，多做一个选项就是假功能。
enum MetricRange {
  day('24h', '24 小时'),
  week('7d', '7 天');

  const MetricRange(this.wire, this.label);

  final String wire;
  final String label;
}

/// 指标曲线状态（按 服务器 × 时间窗 缓存）。
///
/// autoDispose：离开详情页即释放；时间窗切换时旧窗口的结果不需要保留，
/// 保留反而会在切回来时先闪一下旧数据再刷新。
class MetricsNotifier extends StateNotifier<AsyncValue<MetricSeries>> {
  MetricsNotifier(this._repo, this._serverId, this._range)
      : super(const AsyncValue.loading()) {
    load();
  }

  final MetricsRepository _repo;
  final int _serverId;
  final MetricRange _range;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await _fetch();
  }

  Future<void> refresh() => _fetch();

  Future<void> _fetch() async {
    try {
      final data = await _repo.fetch(_serverId, _range.wire);
      state = AsyncValue.data(data);
    } on Object catch (e, st) {
      // 有旧数据时保留旧数据（弱网下曲线比错误页有用），顶部另有 InlineErrorBar 提示。
      if (state is! AsyncData<MetricSeries>) {
        state = AsyncValue.error(e, st);
      }
    }
  }
}

typedef _MetricsKey = ({int serverId, MetricRange range});

final metricsProvider = StateNotifierProvider.autoDispose
    .family<MetricsNotifier, AsyncValue<MetricSeries>, _MetricsKey>(
  (ref, key) => MetricsNotifier(
    ref.watch(metricsRepositoryProvider),
    key.serverId,
    key.range,
  ),
);
