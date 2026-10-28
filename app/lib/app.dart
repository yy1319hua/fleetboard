import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/alerts/presentation/alert_detail_page.dart';
import 'features/alerts/presentation/alerts_page.dart';
import 'features/auth/application/auth_notifier.dart';
import 'features/auth/presentation/login_page.dart';
import 'features/containers/presentation/containers_page.dart';
import 'features/emergency/presentation/update_task_page.dart';
import 'features/overview/application/overview_notifier.dart';
import 'features/overview/presentation/overview_page.dart';
import 'features/overview/presentation/server_detail_page.dart';
import 'features/settings/presentation/settings_page.dart';

/// 全局 ScaffoldMessenger 键：供 App 生命周期层在 onResumed 弹 Toast（7 天硬墙预警）。
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');
final GlobalKey<NavigatorState> _shellNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'shell');

/// 将 AuthNotifier 的状态流桥接为 go_router 的刷新信号（登录态变化即重算重定向）。
class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<dynamic> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<dynamic> _sub;
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// 应用根组件：ProviderScope（main 注入）+ MaterialApp.router。
///
/// 同时是生命周期观察者：
///  - 冷启动 initState 触发 AuthNotifier.tryRestore；
///  - onResumed 触发 access 静默续期（含 7 天硬墙预警）+ 总览前台补拉（更新未读告警）。
class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动恢复会话（含 access 临近过期预刷新）。
    Future.microtask(
      () => ref.read(authNotifierProvider.notifier).tryRestore(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final auth = ref.read(authNotifierProvider.notifier);
    auth.ensureFreshAccessOnResume().then((status) {
      if (status == RefreshWallStatus.warn && mounted) {
        rootScaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('登录即将过期，请尽快重新登录'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    });
    // 前台补拉总览，更新未读告警（B2 到达）。
    ref.read(overviewProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'fleetboard',
      theme: buildAppTheme(),
      routerConfig: router,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 路由表（M9.2 接 AuthNotifier 鉴权重定向）。
///
/// 未登录访问受保护路由 -> 重定向 /login；已登录访问 /login -> 重定向 /overview。
/// alerts/emergency 页 M9.3/4 才填业务，本步沿用占位页。
final goRouterProvider = Provider<GoRouter>((ref) {
  final authNotifier = ref.watch(authNotifierProvider.notifier);
  return GoRouter(
    initialLocation: '/overview',
    navigatorKey: _rootNavigatorKey,
    refreshListenable: _StreamListenable(authNotifier.stream),
    redirect: (BuildContext context, GoRouterState state) {
      final auth = ref.read(authNotifierProvider);
      final loggingIn = state.matchedLocation == '/login';
      // 冷启动恢复中：暂不跳转（由页面显示 loading）。
      if (!auth.initialized) return null;
      if (!auth.isAuthed) return loggingIn ? null : '/login';
      if (loggingIn) return '/overview';
      return null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) =>
            AppShell(state: state, child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/overview',
            builder: (context, state) => const OverviewPage(),
          ),
          GoRoute(
            path: '/alerts',
            builder: (context, state) => const AlertsPage(),
            routes: <RouteBase>[
              GoRoute(
                path: ':alertId',
                builder: (context, state) => AlertDetailPage(
                  alertId: state.pathParameters['alertId'] ?? '',
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsPage(),
          ),
          GoRoute(
            path: '/servers/:serverId',
            builder: (context, state) => ServerDetailPage(
              serverId: state.pathParameters['serverId'] ?? '',
            ),
            routes: <RouteBase>[
              GoRoute(
                path: 'containers',
                builder: (context, state) => ContainersPage(
                  serverId: state.pathParameters['serverId'] ?? '',
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/tasks/update',
            builder: (context, state) => const UpdateTaskPage(),
          ),
        ],
      ),
    ],
  );
});

class _TabItem {
  const _TabItem({
    required this.path,
    required this.label,
    required this.icon,
  });
  final String path;
  final String label;
  final IconData icon;
}

/// 底部三 Tab 壳（总览 / 通知 / 设置）。
///
/// 通知 Tab 角标读取 OverviewNotifier 的 unreadAlerts（前台轮询/onResumed 持续更新）。
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.state,
    required this.child,
  });
  final GoRouterState state;
  final Widget child;

  static const List<_TabItem> _tabs = <_TabItem>[
    _TabItem(path: '/overview', label: '总览', icon: Icons.dashboard_outlined),
    _TabItem(path: '/alerts', label: '通知', icon: Icons.notifications_outlined),
    _TabItem(path: '/settings', label: '设置', icon: Icons.settings_outlined),
  ];

  int get _currentIndex {
    final location = state.matchedLocation;
    for (var i = 0; i < _tabs.length; i++) {
      if (location.startsWith(_tabs[i].path)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(overviewProvider).value?.unreadAlerts ?? 0;
    final index = _currentIndex;
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => context.go(_tabs[i].path),
        destinations: _tabs
            .map(
              (t) => NavigationDestination(
                icon: t.path == '/alerts' && unread > 0
                    ? Badge.count(
                        count: unread,
                        child: Icon(t.icon),
                      )
                    : Icon(t.icon),
                label: t.label,
              ),
            )
            .toList(),
      ),
    );
  }
}
