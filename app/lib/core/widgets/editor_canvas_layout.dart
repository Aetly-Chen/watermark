import 'package:flutter/material.dart';

/// 「画布 + 控制面板」的自适应布局。
///
/// 竖屏（高度充裕）保持设计稿的样子：画布吃掉剩余空间，控制面板压在底部。
///
/// 横屏、分屏、折叠屏半展开这些**高度很矮**的视口里，纯 `Expanded` 会把画布
/// 压成一条 —— 实测 1080×2340 转横屏后，视频页画布只剩约 31dp（93px），
/// 封面帧缩成拇指大一块，标签文字还压在画面上，框选水印根本没可能。
/// 这时改成：画布按比例拿一部分高度，控制面板塞进剩下的空间里**可滚动**，
/// 保证「能看见画布、能摸到按钮」这两件事在任何高度下都成立。
///
/// 只做纵向堆叠，不做左右分栏：控制面板里有 `Row`/`Wrap`/滑杆，
/// 塞进窄列容易横向溢出，收益不如风险大。
class EditorCanvasLayout extends StatelessWidget {
  const EditorCanvasLayout({
    super.key,
    required this.canvas,
    required this.controls,
    this.pinned,
    this.compactHeight = kEditorCompactHeight,
    this.compactCanvasFraction = 0.55,
  });

  /// 画布区域（调用方负责圆角/底色/裁剪）。
  final Widget canvas;

  /// 控制面板区域（自然高度；紧凑模式下会被放进滚动视图）。
  final Widget controls;

  /// 常驻底部、不参与滚动的主操作（比如「开始修复」）。
  ///
  /// 紧凑模式下 [controls] 会变成可滚动；主按钮要是跟着滚，
  /// 用户转成横屏后第一眼就找不到操作入口。
  final Widget? pinned;

  /// 可用高度低于这个值就进入紧凑模式。
  final double compactHeight;

  /// 紧凑模式下画布占可用高度的比例。
  final double compactCanvasFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < compactHeight;
        if (!compact) {
          return Column(
            children: [
              Expanded(child: canvas),
              controls,
              ?pinned,
            ],
          );
        }

        // 比例分配而不是「保底 200dp」：矮到 240dp 时，保底值会把控制面板挤成 0。
        final canvasHeight = constraints.maxHeight * compactCanvasFraction;
        return Column(
          children: [
            SizedBox(height: canvasHeight, child: canvas),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('editor-controls-scroll'),
                child: controls,
              ),
            ),
            ?pinned,
          ],
        );
      },
    );
  }
}

/// 紧凑模式阈值（逻辑像素）。
///
/// 竖屏常见高度：小屏 ~640、主流 ~780、大屏 ~900 —— 都远在阈值之上，不会误触发。
/// 横屏常见高度：~360。分屏下半屏：~390。两者都会落进来。
const double kEditorCompactHeight = 520;
