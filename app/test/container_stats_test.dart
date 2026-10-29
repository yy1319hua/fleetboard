import 'package:app/features/containers/application/container_stats_notifier.dart';
import 'package:app/features/containers/domain/container_stat.dart';
import 'package:flutter_test/flutter_test.dart';

/// 守两组事：
/// ① 短 ID 匹配必须只认「全 ID 的前 12 位」——错配会把 A 容器的 CPU 显示到 B 上，
///    运维照着这个数字判断哪个服务在吃 CPU，错配比不显示更糟。
/// ② 数据不全时必须返回 null 让 UI 显示「无」，不能返回 0% 之类的默认值
///    （0% 会被当成「这个容器很闲」的结论）。
void main() {
  ContainerStat stat(String id) => ContainerStat(
        container: id,
        name: 'web',
        cpuPerc: '0.15%',
        memUsage: '12.3MiB / 1GiB',
        memPerc: '1.23%',
        netIo: '1kB / 2kB',
        blockIo: '0B / 0B',
        pids: '3',
      );

  const fullId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

  test('全 ID 前 12 位命中短 ID', () {
    final map = <String, ContainerStat>{'a1b2c3d4e5f6': stat('a1b2c3d4e5f6')};
    final got = statFor(map, fullId);
    expect(got, isNotNull);
    expect(got!.cpuPerc, '0.15%');
  });

  test('短 ID 不在 map 里时返回 null，而不是随便给一个', () {
    final map = <String, ContainerStat>{'ffffffffffff': stat('ffffffffffff')};
    expect(statFor(map, fullId), isNull);
  });

  test('ID 不足 12 位时返回 null（截断会越界或错配）', () {
    final map = <String, ContainerStat>{'a1b2c3d4e5f6': stat('a1b2c3d4e5f6')};
    expect(statFor(map, 'a1b2c3'), isNull);
    expect(statFor(map, ''), isNull);
  });

  test('空 map 返回 null（stats 尚未拉到或拉取失败时的正常态）', () {
    expect(statFor(const <String, ContainerStat>{}, fullId), isNull);
  });
}
