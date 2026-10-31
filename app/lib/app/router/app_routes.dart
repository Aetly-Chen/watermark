/// 全站路由的单一来源。
///
/// 页面之间只允许用这些常量跳转，禁止在 widget 里手写 `'/history/1'` 这种字符串 ——
/// 改路径时只改这一个文件。带参数的路由一律提供生成函数。
abstract final class AppRoutes {
  // ── 底部 Tab（StatefulShellRoute 的三个分支）──
  static const String home = '/';
  static const String history = '/history';
  static const String profile = '/profile';

  // ── 全屏页（不占 Tab 栏）──
  static const String imageEditor = '/image-editor';
  static const String videoEditor = '/video-editor';
  static const String historyDetailPattern = '/history/:id';

  // ── 路由名，供 goNamed 使用 ──
  static const String homeName = 'home';
  static const String historyName = 'history';
  static const String profileName = 'profile';
  static const String imageEditorName = 'imageEditor';
  static const String videoEditorName = 'videoEditor';
  static const String historyDetailName = 'historyDetail';

  static String historyDetail(String id) => '/history/$id';
}
