import 'package:app/features/containers/application/container_stats_notifier.dart';
import 'package:app/features/containers/application/containers_notifier.dart';
import 'package:app/features/containers/data/containers_repository.dart';
import 'package:app/features/containers/domain/container.dart';
import 'package:app/features/containers/domain/container_action.dart';
import 'package:app/features/containers/domain/container_stat.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只数调用次数，不关心内容。
class _FakeRepo implements ContainersRepository {
  int listCalls = 0;
  int statsCalls = 0;

  @override
  Future<List<Container>> list(int serverId) async {
    listCalls++;
    return const <Container>[];
  }

  @override
  Future<List<ContainerStat>> stats(int serverId) async {
    statsCalls++;
    return const <ContainerStat>[];
  }

  @override
  Future<ContainerActionResult> action(
    int serverId,
    String cid,
    ContainerActionType type,
  ) async =>
      throw UnimplementedError();
}

/// 守的是 S20 那个取舍的两全：切走分段时**既不丢数据/滚动位置，也不继续打 SSH**。
///
/// 之前的做法是「不可见就不构建子树」，滚动位置和已加载列表一起没了；
/// 改成「保留子树 + 下传可见性」之后，必须保证轮询真的会停、回来真的会补拉，
/// 否则就是「看起来没白跑，其实还在每 30 秒开一次远端连接」。
void main() {
  testWidgets('容器轮询：不可见时停止，重新可见时补拉并恢复节奏', (tester) async {
    final fake = _FakeRepo();
    final container = ProviderContainer(
      overrides: [containersRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    // listen 保持 autoDispose provider 存活；只 read 会在下一帧被回收。
    final sub = container.listen(containersProvider(1), (_, __) {});
    addTearDown(sub.close);
    final subStats = container.listen(containerStatsProvider(1), (_, __) {});
    addTearDown(subStats.close);

    final notifier = container.read(containersProvider(1).notifier);
    await tester.pump();
    expect(fake.listCalls, 1, reason: '首次进入应加载一次');

    await tester.pump(const Duration(seconds: 31));
    expect(fake.listCalls, 2, reason: '可见时每 30s 轮询一次');

    notifier.setActive(false);
    await tester.pump(const Duration(seconds: 91));
    expect(fake.listCalls, 2, reason: '不可见期间不应再发请求');

    notifier.setActive(true);
    await tester.pump();
    expect(fake.listCalls, 3, reason: '重新可见应立即补拉，而不是等下一个 30s');

    await tester.pump(const Duration(seconds: 31));
    expect(fake.listCalls, 4, reason: '恢复后应重新按 30s 轮询');

    // 测试结束时不能留着定时器：binding 会断言 timersPending。
    notifier.setActive(false);
    container.read(containerStatsProvider(1).notifier).setActive(false);
  });

  testWidgets('容器占用同样随可见性暂停/恢复', (tester) async {
    final fake = _FakeRepo();
    final container = ProviderContainer(
      overrides: [containersRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    final sub = container.listen(containerStatsProvider(1), (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(containerStatsProvider(1).notifier);
    await tester.pump();
    expect(fake.statsCalls, 1);

    notifier.setActive(false);
    await tester.pump(const Duration(seconds: 91));
    expect(fake.statsCalls, 1, reason: '不可见期间不应轮询 docker stats');

    notifier.setActive(true);
    await tester.pump();
    expect(fake.statsCalls, 2, reason: '重新可见应补拉一次');

    notifier.setActive(false);
  });

  testWidgets('重复 setActive(true) 不重复补拉（didChangeDependencies 可能多次触发）',
      (tester) async {
    final fake = _FakeRepo();
    final container = ProviderContainer(
      overrides: [containersRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    final sub = container.listen(containersProvider(1), (_, __) {});
    addTearDown(sub.close);

    final notifier = container.read(containersProvider(1).notifier);
    await tester.pump();
    expect(fake.listCalls, 1);

    notifier.setActive(true);
    notifier.setActive(true);
    await tester.pump();
    expect(fake.listCalls, 1, reason: '已活跃时重复通知不应产生额外请求');

    notifier.setActive(false);
  });
}
