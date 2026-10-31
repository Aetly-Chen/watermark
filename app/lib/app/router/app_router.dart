import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/history/presentation/history_detail_page.dart';
import '../../features/history/presentation/history_page.dart';
import '../../features/home/presentation/home_page.dart';
import '../../features/image_editor/presentation/image_editor_page.dart';
import '../../features/profile/presentation/profile_page.dart';
import '../../features/video_editor/presentation/video_editor_page.dart';
import '../widgets/app_shell.dart';
import 'app_routes.dart';

part 'app_router.g.dart';

/// 全局唯一的 GoRouter 实例。
///
/// 挂成 Riverpod provider 而不是全局变量，是为了两件事：
/// 1. 测试里可以 `overrideWithValue` 塞一个内存路由，不用起真机；
/// 2. 后续做深链 / 通知跳转时，重定向逻辑可以读别的 provider（登录态、任务状态）。
/// `keepAlive` 必须开：路由器被回收会丢整棵导航栈。
@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    debugLogDiagnostics: false,
    routes: <RouteBase>[
      // ── 三个 Tab：各自独立导航栈 ──
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.home,
                name: AppRoutes.homeName,
                builder: (context, state) => const HomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.history,
                name: AppRoutes.historyName,
                builder: (context, state) => const HistoryPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.profile,
                name: AppRoutes.profileName,
                builder: (context, state) => const ProfilePage(),
              ),
            ],
          ),
        ],
      ),

      // ── 全屏页：盖住 Tab 栏，带返回 ──
      GoRoute(
        path: AppRoutes.imageEditor,
        name: AppRoutes.imageEditorName,
        builder: (context, state) => const ImageEditorPage(),
      ),
      GoRoute(
        path: AppRoutes.videoEditor,
        name: AppRoutes.videoEditorName,
        builder: (context, state) => const VideoEditorPage(),
      ),
      GoRoute(
        path: AppRoutes.historyDetailPattern,
        name: AppRoutes.historyDetailName,
        builder: (context, state) =>
            HistoryDetailPage(taskId: state.pathParameters['id'] ?? ''),
      ),
    ],
  );
}
