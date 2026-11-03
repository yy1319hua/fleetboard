import 'package:app/core/widgets/tab_refresh_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 探针：模拟一个真实分段（注册自己、销毁时解绑）。
class _Probe extends StatefulWidget {
  const _Probe({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with TabRefreshBinding<_Probe> {
  @override
  Future<void> refreshTab() => widget.onRefresh();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget _host(TabRefreshSlot slot, Widget child) => MaterialApp(
      home: TabRefreshScope(slot: slot, child: child),
    );

void main() {
  testWidgets('分段注册后，父级通过句柄能刷到它', (tester) async {
    final slot = TabRefreshSlot();
    var calls = 0;

    await tester.pumpWidget(_host(slot, _Probe(onRefresh: () async => calls++)));

    expect(slot.hasHandler, isTrue, reason: '进入分段即应完成注册');
    await slot.run();
    expect(calls, 1);
  });

  testWidgets('分段销毁后自动解绑：句柄不会指向已销毁的 State', (tester) async {
    final slot = TabRefreshSlot();
    var calls = 0;

    await tester.pumpWidget(_host(slot, _Probe(onRefresh: () async => calls++)));
    await slot.run();
    expect(calls, 1, reason: '先确认注册确实生效，避免把「本来就没注册」误判成「解绑成功」');

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(slot.hasHandler, isFalse, reason: 'dispose 必须解绑，否则父级按按钮会打到已销毁对象');
    await slot.run();
    expect(calls, 1, reason: '解绑后不应再触发');
  });

  testWidgets('两个分段各有句柄，互不干扰', (tester) async {
    final slotA = TabRefreshSlot();
    final slotB = TabRefreshSlot();
    var a = 0;
    var b = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            Expanded(
              child: TabRefreshScope(
                slot: slotA,
                child: _Probe(onRefresh: () async => a++),
              ),
            ),
            Expanded(
              child: TabRefreshScope(
                slot: slotB,
                child: _Probe(onRefresh: () async => b++),
              ),
            ),
          ],
        ),
      ),
    );

    // 父页按当前段索引取句柄，取到谁就只刷谁——这正是「按钮刷当前分段」的语义。
    await slotB.run();
    expect(b, 1);
    expect(a, 0);
  });

  test('没有分段注册时，run 静默返回而不是抛异常', () async {
    final slot = TabRefreshSlot();
    expect(slot.hasHandler, isFalse);
    await slot.run();
  });
}
