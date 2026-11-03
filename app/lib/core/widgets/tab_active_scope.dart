import 'package:flutter/widgets.dart';

/// 把「所在分段当前是否可见」传递给子树。
///
/// 为什么需要它：详情页用 KeepAlive 保留了各段子树（切回来不重拉、滚动位置不丢），
/// 代价是这些子树里的轮询（容器列表/占用各一条 30s SSH）在用户已经切走之后仍然照跑。
/// 而如果改成「切走就销毁子树」，滚动位置和已加载的数据又会一起丢掉。
///
/// 所以把两件事拆开：**子树保留（数据与位置在），可见性下传（轮询按需停）**。
/// 各段自己决定拿到 false 时要停什么——目前只有容器列表与容器占用两条定时器。
class TabActiveScope extends InheritedWidget {
  const TabActiveScope({super.key, required this.active, required super.child});

  /// true 表示该分段当前正被展示。
  final bool active;

  /// 读取可见性；不在详情页分段内（如独立路由页）时默认 true。
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabActiveScope>()?.active ??
      true;

  @override
  bool updateShouldNotify(TabActiveScope oldWidget) =>
      active != oldWidget.active;
}
