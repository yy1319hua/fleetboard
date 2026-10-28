import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/alerts/presentation/alert_detail_page.dart';
import 'features/alerts/presentation/alerts_page.dart';
import 'features/auth/presentation/login_page.dart';
import 'features/emergency/presentation/update_task_page.dart';
import 'features/overview/presentation/overview_page.dart';
import 'features/overview/presentation/server_detail_page.dart';
import 'features/settings/presentation/settings_page.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');
final GlobalKey<NavigatorState> _shellNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'shell');

/// 应用根组件：ProviderScope（main 注入）+ MaterialApp.router(routerConfig)。
class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'fleetboard',
      theme: buildAppTheme(),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 路由表（M9.1 可编译空壳 + 鉴权重定向占位）。
///
/// M9.2 将在此接 AuthNotifier：未登录访问受保护路由 -> 重定向 /login；
/// 已登录访问 /login -> 重定向首个 Tab。guard 通过 [GoRouter.redirect] 标注。
final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/overview',
    navigatorKey: _rootNavigatorKey,
    // M9.2: redirect: (context, state) { ... } 鉴权重定向到 /login。
    routes: <RouteBase>[
      // 无壳登录页
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      // 底部三 Tab 壳
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => AppShell(state: state, child: child),
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
          // 二级占位（服务器详情 / 包更新）；M9.3/4 接业务与全屏 overlay。
          GoRoute(
            path: '/servers/:serverId',
            builder: (context, state) => ServerDetailPage(
              serverId: state.pathParameters['serverId'] ?? '',
            ),
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
/// M9.1 采用 ShellRoute（M9 方案 §3.1 曾提 StatefulShellRoute；
/// 本步以 ShellRoute 起步，若 M9.2+ 需要各 Tab 保留独立导航栈，
/// 再升级为 StatefulShellRoute.indexedStack，不推翻已批准选型）。
class AppShell extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final index = _currentIndex;
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) {
          // 切 Tab 用 go（非 push），避免栈累积。
          context.go(_tabs[i].path);
        },
        destinations: _tabs
            .map(
              (t) => NavigationDestination(
                icon: Icon(t.icon),
                label: t.label,
              ),
            )
            .toList(),
      ),
    );
  }
}
