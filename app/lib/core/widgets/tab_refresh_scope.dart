import 'package:flutter/widgets.dart';

/// 一个分段的「刷新入口」句柄。
///
/// 为什么需要它：刷新按钮挂在详情页 AppBar 上，五个分段都看得见，但它原先只
/// 调 `overviewProvider.refresh()`——切到容器/监控/文件时点了没有任何反应。
/// 而各分段的数据源（含时间窗、当前目录这类只存在于分段内部的状态）父级拿不到，
/// 只能由分段自己把「刷新我」这件事交出来。
///
/// 于是 AppBar 按钮问「当前段有句柄吗」：有就执行它，没有（还没注册或该段本就
/// 没有刷新语义）再回退到概览刷新。
class TabRefreshSlot {
  Future<void> Function()? _handler;

  bool get hasHandler => _handler != null;

  void bind(Future<void> Function() handler) {
    _handler = handler;
  }

  void unbind() {
    _handler = null;
  }

  Future<void> run() async {
    final handler = _handler;
    if (handler == null) return;
    await handler();
  }
}

/// 把本段的刷新句柄下发给子树。
///
/// 只承载句柄，不参与重建：句柄变化不需要通知父级，`updateShouldNotify`
/// 按对象身份比较即可。
class TabRefreshScope extends InheritedWidget {
  const TabRefreshScope({
    super.key,
    required this.slot,
    required super.child,
  });

  final TabRefreshSlot slot;

  /// 不在详情页分段内（如独立全屏路由）时返回 null，调用方自行忽略。
  static TabRefreshSlot? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabRefreshScope>()?.slot;

  @override
  bool updateShouldNotify(TabRefreshScope oldWidget) => slot != oldWidget.slot;
}

/// 让分段用三行代码接入 AppBar 刷新：`with TabRefreshBinding` + 实现 [refreshTab]。
///
/// 用 mixin 而不是让每段自己写 didChangeDependencies/dispose，是因为「注册了
/// 却忘了解绑」会留下一个指向已销毁 State 的闭包——父级一按按钮就 setState
/// after dispose。把解绑放进 dispose 是唯一不会漏的写法。
mixin TabRefreshBinding<T extends StatefulWidget> on State<T> {
  TabRefreshSlot? _slot;

  /// 各分段实现：刷新本段自己的数据源。
  Future<void> refreshTab();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final slot = TabRefreshScope.maybeOf(context);
    if (identical(slot, _slot)) return;
    _slot?.unbind();
    _slot = slot;
    slot?.bind(refreshTab);
  }

  @override
  void dispose() {
    _slot?.unbind();
    _slot = null;
    super.dispose();
  }
}
