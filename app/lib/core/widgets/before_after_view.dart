import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 修复前后的三种看法。对应原型结果页顶部的 `修复前 / 对比 / 修复后` 三段。
enum CompareMode {
  /// 整张看原图（带水印那张）
  before,

  /// 左右分屏，中间一条可拖的分界线
  compare,

  /// 整张看结果
  after,
}

/// 修复前后对比。[before] 是底层，[after] 从分界线**右侧**露出来 ——
/// 和原型一致（`cmpLayer.clipPath = inset(0 0 0 <split>%)`）：
/// 分界线左边是「修复前」，右边是「修复后」。
///
/// 收 [Widget] 而不是文件路径，是为了以后视频结果页能直接复用
/// （原型的视频结果页也有同一套对比分屏，只是数据源换成一帧画面）。
///
/// 分界线位置是**内部状态**：切到「修复前」再切回来，用户拖到哪还在哪，
/// 不该被父级的重建冲掉。
class BeforeAfterView extends StatefulWidget {
  const BeforeAfterView({
    super.key,
    required this.before,
    required this.after,
    this.mode = CompareMode.compare,
    this.imageAspect,
  });

  final Widget before;
  final Widget after;
  final CompareMode mode;

  /// 图片（或视频封面帧）的宽高比。给了就把对比画面收成这个比例，
  /// 分界线按图片宽度算 —— 面板比例和图片差得远时（横屏）必须给，不然分界线会跑到图外。
  final double? imageAspect;

  @override
  State<BeforeAfterView> createState() => _BeforeAfterViewState();
}

class _BeforeAfterViewState extends State<BeforeAfterView> {
  /// 分界线占宽度的比例。夹在 [minSplit]..[maxSplit] 之间：
  /// 拖到 0 会让把手压到边缘、手指没地方抓回来；留一点余量。
  static const double minSplit = 0.02;
  static const double maxSplit = 0.98;

  double _split = 0.5;

  void _moveBy(double deltaPx, double width) {
    if (width <= 0) return;
    final next = (_split + deltaPx / width).clamp(minSplit, maxSplit);
    if (next == _split) return;
    setState(() => _split = next);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    switch (widget.mode) {
      case CompareMode.before:
        return KeyedSubtree(
          key: const ValueKey('compare-before'),
          child: widget.before,
        );
      case CompareMode.after:
        return KeyedSubtree(
          key: const ValueKey('compare-after'),
          child: widget.after,
        );
      case CompareMode.compare:
        return LayoutBuilder(
          builder: (context, constraints) {
            // 传了 imageAspect 就把对比画面收成图片自身的比例。
            //
            // 不这么做的话，面板比图片宽很多时（真机横屏就是这样：面板 2100px 宽、
            // 图片按高度只占 231dp）画面会被 letterbox 成中间一小条，而分界线仍按
            // **面板宽度**算 —— 把手落到图片外面，右边那半直接看不见，
            // 整个结果页读起来就是「坏了」。
            final aspect = widget.imageAspect;
            var width = constraints.maxWidth;
            var height = constraints.maxHeight;
            if (aspect != null && aspect > 0 && height > 0) {
              if (width / height > aspect) {
                width = height * aspect;
              } else {
                height = width / aspect;
              }
            }
            final x = width * _split;
            final stack = Stack(
              key: const ValueKey('compare-split'),
              fit: StackFit.expand,
              children: [
                widget.before,
                // 只露出分界线右边的部分。
                //
                // 这里**刻意不用 `ClipRect(clipper: 自定义clipper)`**：那个写法要多写一个
                // `shouldReclip`，而它写错时的现象是「把手滑过去了、图停在原处」——
                // 单测里量把手位置照样绿（我试过：把它改成 `=> false`，用例仍然通过，
                // 因为用例读到的是 clipper 现算的值，不是真正画出来的裁剪）。
                // 换成 Positioned + ClipRect + OverflowBox 后，可见区域的左边界就是
                // ClipRect 自己的位置，测得的和画出来的是同一个数。
                //
                // 也不能用 `Align(widthFactor:)`：那会改子树的约束，图被二次缩放，
                // 和左边那张对不上。OverflowBox 强行给回整幅尺寸，两张图严丝合缝。
                Positioned(
                  key: const ValueKey('compare-after-clip'),
                  left: x,
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: width,
                      maxWidth: width,
                      minHeight: height,
                      maxHeight: height,
                      child: widget.after,
                    ),
                  ),
                ),
                Positioned(
                  left: x - 24,
                  top: 0,
                  bottom: 0,
                  width: 48,
                  child: GestureDetector(
                    key: const ValueKey('compare-divider'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) =>
                        _moveBy(details.delta.dx, width),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(width: 2, color: t.paper),
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: t.paper,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.22),
                                blurRadius: 6,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.compare_arrows_rounded,
                            size: 18,
                            color: t.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const _Tag(
                  key: ValueKey('compare-tag-before'),
                  text: '修复前',
                  alignedLeft: true,
                ),
                const _Tag(
                  key: ValueKey('compare-tag-after'),
                  text: '修复后',
                  alignedLeft: false,
                ),
              ],
            );
            if (aspect == null || aspect <= 0) return stack;
            return Center(
              child: SizedBox(width: width, height: height, child: stack),
            );
          },
        );
    }
  }
}

/// 「修复前 / 对比 / 修复后」三段 + 对比画面，整块可直接放进结果页。
///
/// 图片结果页和视频结果页都要这一套（原型的 `segImg` 与 `segVideo` 也是同一套），
/// 抽在这里省得两边各写一份 —— 尤其角标的位置，写错一次（放顶部）就会和分段控件撞成
/// 一行五个标签，真机上一眼看到才发现。
class BeforeAfterSwitch extends StatefulWidget {
  const BeforeAfterSwitch({
    super.key,
    required this.before,
    required this.after,
    this.initialMode = CompareMode.compare,
    this.imageAspect,
  });

  final Widget before;
  final Widget after;

  /// 图片宽高比，透传给内部的 [BeforeAfterView]。
  final double? imageAspect;

  /// 默认「对比」：切来切去看不出差别，并排才看得清。
  final CompareMode initialMode;

  @override
  State<BeforeAfterSwitch> createState() => _BeforeAfterSwitchState();
}

class _BeforeAfterSwitchState extends State<BeforeAfterSwitch> {
  late CompareMode _mode = widget.initialMode;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: BeforeAfterView(
            before: widget.before,
            after: widget.after,
            mode: _mode,
            imageAspect: widget.imageAspect,
          ),
        ),
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              key: const ValueKey('compare-seg'),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: t.media.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SegmentLabel(
                    key: const ValueKey('compare-mode-before'),
                    label: '修复前',
                    selected: _mode == CompareMode.before,
                    onTap: () => setState(() => _mode = CompareMode.before),
                  ),
                  _SegmentLabel(
                    key: const ValueKey('compare-mode-compare'),
                    label: '对比',
                    selected: _mode == CompareMode.compare,
                    onTap: () => setState(() => _mode = CompareMode.compare),
                  ),
                  _SegmentLabel(
                    key: const ValueKey('compare-mode-after'),
                    label: '修复后',
                    selected: _mode == CompareMode.after,
                    onTap: () => setState(() => _mode = CompareMode.after),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? t.paper : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? t.ink : t.cream.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    super.key,
    required this.text,
    required this.alignedLeft,
  });

  final String text;
  final bool alignedLeft;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    // 角标放**底部**。原型把它们放在画面顶部（`.tag.a{left:9px}`），
    // 那是因为原型的 `修复前/对比/修复后` 分段在顶部栏里、不占画面；
    // 我们的分段是浮在画布顶部中央的 —— 照抄就会变成一行五个标签
    // 「修复前 修复前 对比 修复后 修复后」（真机截图 2026-10-25 就是这样）。
    return Positioned(
      left: alignedLeft ? 9 : null,
      right: alignedLeft ? null : 9,
      bottom: 9,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: t.media.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: t.cream,
          ),
        ),
      ),
    );
  }
}
