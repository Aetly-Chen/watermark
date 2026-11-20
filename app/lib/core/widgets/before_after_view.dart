import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 修复前后的三种看法。对应结果页控制栏的 `修复前 / 对比 / 修复后` 三段。
enum CompareMode {
  /// 整张看原图（带水印那张）
  before,

  /// 左右分屏，中间一条可拖的分界线
  compare,

  /// 整张看结果
  after,
}

/// 修复前后对比。[before] 是底层，[after] 从分界线**右侧**露出来 ——
/// 分界线左边是「修复前」，右边是「修复后」。
///
/// 收 [Widget] 而不是文件路径，是为了让图片与视频结果页都能直接复用。
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
                // 只露出分界线右边的部分：
                // Alignment.topRight 让 OverflowBox 把与 width 的差值（-x）向左侧溢出，
                // 从而使 widget.after 的 (0,0) 与 widget.before 严格 1:1 重合。
                Positioned(
                  key: const ValueKey('compare-after-clip'),
                  left: x,
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topRight,
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
                    child: _DividerHandle(
                      handleSize: 32,
                      lineColor: Colors.white.withValues(alpha: 0.92),
                      borderColor: t.flame,
                      fillColor: t.paper,
                      iconColor: t.ink,
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

/// 「修复前 / 对比 / 修复后」三段 + 对比画面 + 全屏缩放对比入口。
///
/// 采用纵向结构（画布在上、独立控制栏在下），避免悬浮分段遮挡画面内容或与角标冲突。
class BeforeAfterSwitch extends StatefulWidget {
  const BeforeAfterSwitch({
    super.key,
    required this.before,
    required this.after,
    this.initialMode = CompareMode.compare,
    this.imageAspect,
    this.title = '对比预览',
    this.enableFullscreen = true,
  });

  final Widget before;
  final Widget after;

  /// 图片宽高比，透传给内部的 [BeforeAfterView]。
  final double? imageAspect;

  /// 默认「对比」：切来切去看不出差别，并排才看得清。
  final CompareMode initialMode;

  /// 全屏对比弹窗标题。
  final String title;

  /// 是否在底部控制栏右侧展示全屏对比按钮。
  final bool enableFullscreen;

  @override
  State<BeforeAfterSwitch> createState() => _BeforeAfterSwitchState();
}

class _BeforeAfterSwitchState extends State<BeforeAfterSwitch> {
  late CompareMode _mode = widget.initialMode;

  Future<void> _openFullscreen() {
    return FullscreenCompareDialog.show(
      context,
      before: widget.before,
      after: widget.after,
      initialMode: _mode,
      imageAspect: widget.imageAspect,
      title: widget.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return ColoredBox(
      color: t.media,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 树顺序保持 BeforeAfterView 在前、控制栏在后，
          // 确保测试里 find.text('修复前'/'修复后').last 命中分段控件且角标位于分段上方。
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: BeforeAfterView(
                before: widget.before,
                after: widget.after,
                mode: _mode,
                imageAspect: widget.imageAspect,
              ),
            ),
          ),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Row(
              children: [
                if (widget.enableFullscreen) const SizedBox(width: 36),
                Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _CompareSegmentBar(
                        key: const ValueKey('compare-seg'),
                        mode: _mode,
                        onChanged: (next) => setState(() => _mode = next),
                        itemKeyPrefix: 'compare-mode',
                      ),
                    ),
                  ),
                ),
                if (widget.enableFullscreen)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      key: const ValueKey('compare-fullscreen'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      style: IconButton.styleFrom(
                        hoverColor: Colors.white.withValues(alpha: 0.14),
                        highlightColor: t.hoverTint,
                      ),
                      onPressed: _openFullscreen,
                      tooltip: '全屏对比',
                      icon: Icon(
                        Icons.open_in_full_rounded,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏缩放与分屏对比弹窗。
///
/// 支持双指缩放（1.0×–6.0×）、单指拖拽平移、双击切换 1× 与铺宽/2.5×，
/// 以及高竖图（imageAspect < viewportAspect * 0.72）一键铺宽查看（从顶部开始纵向滑看）。
class FullscreenCompareDialog extends StatefulWidget {
  const FullscreenCompareDialog({
    super.key,
    required this.before,
    required this.after,
    this.initialMode = CompareMode.compare,
    this.imageAspect,
    this.title = '对比预览',
  });

  final Widget before;
  final Widget after;
  final CompareMode initialMode;
  final double? imageAspect;
  final String title;

  static Future<void> show(
    BuildContext context, {
    required Widget before,
    required Widget after,
    CompareMode initialMode = CompareMode.compare,
    double? imageAspect,
    String title = '对比预览',
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      useSafeArea: false,
      builder: (_) => FullscreenCompareDialog(
        before: before,
        after: after,
        initialMode: initialMode,
        imageAspect: imageAspect,
        title: title,
      ),
    );
  }

  @override
  State<FullscreenCompareDialog> createState() =>
      _FullscreenCompareDialogState();
}

class _FullscreenCompareDialogState extends State<FullscreenCompareDialog> {
  static const double _minScale = 1.0;
  static const double _maxScale = 6.0;
  static const double _minSplit = 0.02;
  static const double _maxSplit = 0.98;

  late CompareMode _mode = widget.initialMode;
  double _split = 0.5;
  double _scale = 1.0;
  Offset _offset = Offset.zero;

  double _gestureStartScale = 1.0;
  Offset _gestureStartOffset = Offset.zero;
  Offset _gestureStartFocal = Offset.zero;
  Offset? _doubleTapPos;

  Size _computeBaseSize(double vw, double vh) {
    final aspect = widget.imageAspect;
    if (aspect == null || aspect <= 0 || vw <= 0 || vh <= 0) {
      return Size(vw, vh);
    }
    if (vw / vh > aspect) {
      return Size(vh * aspect, vh);
    }
    return Size(vw, vw / aspect);
  }

  bool _isTallImage(double vw, double vh) {
    final aspect = widget.imageAspect;
    if (aspect == null || aspect <= 0 || vw <= 0 || vh <= 0) return false;
    final viewportAspect = vw / vh;
    return aspect < viewportAspect * 0.72;
  }

  double _fitWidthScale(double vw, Size baseSize) {
    if (baseSize.width <= 0) return 1.0;
    return (vw / baseSize.width).clamp(_minScale, _maxScale);
  }

  Offset _clampOffset(
    Offset raw,
    double scale,
    double vw,
    double vh,
    Size baseSize,
  ) {
    final scaledW = baseSize.width * scale;
    final scaledH = baseSize.height * scale;
    final tx = scaledW <= vw
        ? (vw - scaledW) / 2
        : raw.dx.clamp(vw - scaledW, 0.0);
    final ty = scaledH <= vh
        ? (vh - scaledH) / 2
        : raw.dy.clamp(vh - scaledH, 0.0);
    return Offset(tx, ty);
  }

  void _moveSplit(double deltaPx, double vw) {
    if (vw <= 0) return;
    final next = (_split + deltaPx / vw).clamp(_minSplit, _maxSplit);
    if (next == _split) return;
    setState(() => _split = next);
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartOffset = _offset;
    _gestureStartFocal = details.localFocalPoint;
  }

  void _handleScaleUpdate(
    ScaleUpdateDetails details,
    double vw,
    double vh,
    Size baseSize,
  ) {
    final nextScale =
        (_gestureStartScale * details.scale).clamp(_minScale, _maxScale);
    final ratio = _gestureStartScale == 0 ? 1.0 : nextScale / _gestureStartScale;
    final rawOffset =
        details.localFocalPoint - (_gestureStartFocal - _gestureStartOffset) * ratio;
    final clamped = _clampOffset(rawOffset, nextScale, vw, vh, baseSize);
    setState(() {
      _scale = nextScale;
      _offset = clamped;
    });
  }

  void _handleDoubleTap(double vw, double vh, Size baseSize) {
    if (_scale > 1.02) {
      setState(() {
        _scale = 1.0;
        _offset = _clampOffset(Offset.zero, 1.0, vw, vh, baseSize);
      });
      return;
    }

    final isTall = _isTallImage(vw, vh);
    final fitWidth = _fitWidthScale(vw, baseSize);
    final targetScale = isTall ? fitWidth : 2.5;
    final focal = _doubleTapPos ?? Offset(vw / 2, vh / 2);
    final clampedCurrent = _clampOffset(_offset, _scale, vw, vh, baseSize);
    final ratio = targetScale / _scale;
    final rawOffset = focal - (focal - clampedCurrent) * ratio;
    setState(() {
      _scale = targetScale;
      _offset = _clampOffset(rawOffset, targetScale, vw, vh, baseSize);
    });
  }

  void _toggleFit(double vw, double vh, Size baseSize) {
    if (_scale > 1.02) {
      setState(() {
        _scale = 1.0;
        _offset = _clampOffset(Offset.zero, 1.0, vw, vh, baseSize);
      });
      return;
    }

    final fitWidth = _fitWidthScale(vw, baseSize);
    final useFitWidth = _isTallImage(vw, vh) || fitWidth > 1.05;
    final targetScale = useFitWidth ? fitWidth : 2.5;
    final rawOffset = useFitWidth
        ? Offset.zero
        : Offset(
            vw / 2 - baseSize.width * targetScale / 2,
            vh / 2 - baseSize.height * targetScale / 2,
          );
    setState(() {
      _scale = targetScale;
      _offset = _clampOffset(rawOffset, targetScale, vw, vh, baseSize);
    });
  }

  Widget _buildTransformedLayer(Widget child, Size baseSize, Matrix4 matrix) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: baseSize.width,
          height: baseSize.height,
          child: Transform(
            transform: matrix,
            alignment: Alignment.topLeft,
            child: child,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Dialog(
      backgroundColor: t.media,
      surfaceTintColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(),
      child: Semantics(
        label: widget.title,
        child: SizedBox.expand(
          child: ColoredBox(
            color: t.media,
            child: _FullscreenScaffoldBody(
              mode: _mode,
              scale: _scale,
              split: _split,
              isTallFn: _isTallImage,
              fitWidthFn: _fitWidthScale,
              computeBaseSize: _computeBaseSize,
              clampOffset: _clampOffset,
              offset: _offset,
              onModeChanged: (next) => setState(() => _mode = next),
              onClose: () => Navigator.of(context).pop(),
              onToggleFit: _toggleFit,
              onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
              onDoubleTap: _handleDoubleTap,
              onScaleStart: _handleScaleStart,
              onScaleUpdate: _handleScaleUpdate,
              onSplitDrag: _moveSplit,
              buildLayer: _buildTransformedLayer,
              before: widget.before,
              after: widget.after,
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenScaffoldBody extends StatelessWidget {
  const _FullscreenScaffoldBody({
    required this.mode,
    required this.scale,
    required this.split,
    required this.isTallFn,
    required this.fitWidthFn,
    required this.computeBaseSize,
    required this.clampOffset,
    required this.offset,
    required this.onModeChanged,
    required this.onClose,
    required this.onToggleFit,
    required this.onDoubleTapDown,
    required this.onDoubleTap,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onSplitDrag,
    required this.buildLayer,
    required this.before,
    required this.after,
  });

  final CompareMode mode;
  final double scale;
  final double split;
  final bool Function(double vw, double vh) isTallFn;
  final double Function(double vw, Size baseSize) fitWidthFn;
  final Size Function(double vw, double vh) computeBaseSize;
  final Offset Function(
    Offset raw,
    double scale,
    double vw,
    double vh,
    Size baseSize,
  ) clampOffset;
  final Offset offset;
  final ValueChanged<CompareMode> onModeChanged;
  final VoidCallback onClose;
  final void Function(double vw, double vh, Size baseSize) onToggleFit;
  final GestureTapDownCallback onDoubleTapDown;
  final void Function(double vw, double vh, Size baseSize) onDoubleTap;
  final GestureScaleStartCallback onScaleStart;
  final void Function(
    ScaleUpdateDetails details,
    double vw,
    double vh,
    Size baseSize,
  ) onScaleUpdate;
  final void Function(double deltaPx, double vw) onSplitDrag;
  final Widget Function(Widget child, Size baseSize, Matrix4 matrix) buildLayer;
  final Widget before;
  final Widget after;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final safeTop = MediaQuery.paddingOf(context).top;
    const toolbarHeight = 52.0;

    return LayoutBuilder(
      builder: (context, total) {
        final vw = total.maxWidth;
        final vh = math.max(1.0, total.maxHeight - safeTop - toolbarHeight);
        final baseSize = computeBaseSize(vw, vh);
        final isTall = isTallFn(vw, vh);
        final fitWidth = fitWidthFn(vw, baseSize);
        final fitLabel = scale > 1.02
            ? '适应'
            : (isTall || fitWidth > 1.05 ? '铺宽' : '放大');

        final clampedOffset = clampOffset(offset, scale, vw, vh, baseSize);
        final matrix = Matrix4.diagonal3Values(scale, scale, 1.0)
          ..setTranslationRaw(clampedOffset.dx, clampedOffset.dy, 0.0);
        final splitX = vw * split;

        final beforeLayer = buildLayer(before, baseSize, matrix);
        final afterLayer = buildLayer(after, baseSize, matrix);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: EdgeInsets.only(top: safeTop, left: 6, right: 10),
              height: safeTop + toolbarHeight,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.32),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: IconButton(
                      key: const ValueKey('fullscreen-compare-close'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      style: IconButton.styleFrom(
                        hoverColor: Colors.white.withValues(alpha: 0.14),
                        highlightColor: t.hoverTint,
                      ),
                      onPressed: onClose,
                      tooltip: '关闭',
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _CompareSegmentBar(
                          key: const ValueKey('fullscreen-compare-seg'),
                          mode: mode,
                          onChanged: onModeChanged,
                          itemKeyPrefix: 'fullscreen-compare-mode',
                        ),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${scale.toStringAsFixed(1)}×',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Material(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: const ValueKey('fullscreen-compare-fit'),
                          onTap: () => onToggleFit(vw, vh, baseSize),
                          borderRadius: BorderRadius.circular(8),
                          hoverColor: Colors.white.withValues(alpha: 0.14),
                          focusColor: Colors.white.withValues(alpha: 0.14),
                          splashColor: t.flame.withValues(alpha: 0.24),
                          highlightColor: t.hoverTint,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 5,
                            ),
                            child: Text(
                              fitLabel,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 底层统一缩放/平移手势层（处于分界线下方，分界线热区内手势不会冒泡到这里）
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: onDoubleTapDown,
                        onDoubleTap: () => onDoubleTap(vw, vh, baseSize),
                        onScaleStart: onScaleStart,
                        onScaleUpdate: (d) =>
                            onScaleUpdate(d, vw, vh, baseSize),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (mode != CompareMode.after) beforeLayer,
                            if (mode == CompareMode.after) afterLayer,
                            if (mode == CompareMode.compare)
                              Positioned(
                                key: const ValueKey(
                                  'fullscreen-compare-after-clip',
                                ),
                                left: splitX,
                                top: 0,
                                right: 0,
                                bottom: 0,
                                child: ClipRect(
                                  child: OverflowBox(
                                    alignment: Alignment.topRight,
                                    minWidth: vw,
                                    maxWidth: vw,
                                    minHeight: vh,
                                    maxHeight: vh,
                                    child: afterLayer,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // 独立处于视口坐标系内的分界线（48dp 热区）
                    if (mode == CompareMode.compare)
                      Positioned(
                        left: splitX - 24,
                        top: 0,
                        bottom: 0,
                        width: 48,
                        child: GestureDetector(
                          key: const ValueKey('fullscreen-compare-divider'),
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (d) =>
                              onSplitDrag(d.delta.dx, vw),
                          child: _DividerHandle(
                            handleSize: 34,
                            lineColor: Colors.white.withValues(alpha: 0.92),
                            borderColor: t.flame,
                            fillColor: t.paper,
                            iconColor: t.ink,
                          ),
                        ),
                      ),
                    if (mode == CompareMode.compare) ...const [
                      _Tag(
                        key: ValueKey('fullscreen-compare-tag-before'),
                        text: '修复前',
                        alignedLeft: true,
                        bottomOffset: 14,
                      ),
                      _Tag(
                        key: ValueKey('fullscreen-compare-tag-after'),
                        text: '修复后',
                        alignedLeft: false,
                        bottomOffset: 14,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CompareSegmentBar extends StatelessWidget {
  const _CompareSegmentBar({
    super.key,
    required this.mode,
    required this.onChanged,
    required this.itemKeyPrefix,
  });

  final CompareMode mode;
  final ValueChanged<CompareMode> onChanged;
  final String itemKeyPrefix;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SegmentLabel(
            key: ValueKey('$itemKeyPrefix-before'),
            label: '修复前',
            selected: mode == CompareMode.before,
            onTap: () => onChanged(CompareMode.before),
          ),
          _SegmentLabel(
            key: ValueKey('$itemKeyPrefix-compare'),
            label: '对比',
            selected: mode == CompareMode.compare,
            onTap: () => onChanged(CompareMode.compare),
          ),
          _SegmentLabel(
            key: ValueKey('$itemKeyPrefix-after'),
            label: '修复后',
            selected: mode == CompareMode.after,
            onTap: () => onChanged(CompareMode.after),
          ),
        ],
      ),
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
    final radius = BorderRadius.circular(7);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? t.flame : Colors.transparent,
        borderRadius: radius,
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: selected
              ? t.onFlame.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.14),
          focusColor: selected
              ? t.onFlame.withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.14),
          splashColor: selected
              ? t.onFlame.withValues(alpha: 0.18)
              : t.hoverTint,
          highlightColor: selected
              ? t.onFlame.withValues(alpha: 0.10)
              : t.hoverTint,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? t.onFlame
                    : Colors.white.withValues(alpha: 0.78),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DividerHandle extends StatelessWidget {
  const _DividerHandle({
    required this.handleSize,
    required this.lineColor,
    required this.borderColor,
    required this.fillColor,
    required this.iconColor,
  });

  final double handleSize;
  final Color lineColor;
  final Color borderColor;
  final Color fillColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: lineColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.30),
                blurRadius: 3,
              ),
            ],
          ),
          child: const SizedBox(width: 2, height: double.infinity),
        ),
        Container(
          width: handleSize,
          height: handleSize,
          decoration: BoxDecoration(
            color: fillColor,
            shape: BoxShape.circle,
            border: Border.all(color: borderColor, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.24),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            Icons.compare_arrows_rounded,
            size: 18,
            color: iconColor,
          ),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({
    super.key,
    required this.text,
    required this.alignedLeft,
    this.bottomOffset = 9,
  });

  final String text;
  final bool alignedLeft;
  final double bottomOffset;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: alignedLeft ? 9 : null,
      right: alignedLeft ? null : 9,
      bottom: bottomOffset,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.56),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
