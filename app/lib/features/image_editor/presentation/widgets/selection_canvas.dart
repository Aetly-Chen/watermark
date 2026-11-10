import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../domain/mask_draft.dart';

/// 图片画布 + 遮罩草稿（矩形 / 涂抹 / 橡皮）。
///
/// 坐标系有三层，别混：
/// 1. **显示坐标**：`RenderBox` 的 local 坐标（手势拿到的就是这个）；
/// 2. **图像显示矩形**：图片按 `BoxFit.contain` 摆在画布里的实际位置（有留白）；
/// 3. **归一化坐标 0..1**：只把这一层交给外面，`MaskComposer` 再乘回原图像素 ——
///    这样换设备、换屏幕尺寸、换缩略图策略都不会让遮罩错位。
///
/// 笔迹的**宽度换算也只在这里做**：状态里存的是「手指多粗」（逻辑像素，8..60），
/// 归一化 = 逻辑像素 / 渲染宽度。让上层去算这个，就等于逼它知道画布有多宽。
class SelectionCanvas extends StatefulWidget {
  const SelectionCanvas({
    required this.bytes,
    required this.imageSize,
    required this.draft,
    required this.tool,
    required this.brushSize,
    required this.onDraftChanged,
    this.onGestureStart,
    this.onGestureEnd,
    super.key,
  });

  final Uint8List bytes;
  final Size imageSize;
  final MaskDraft draft;
  final MaskTool tool;

  /// 画笔直径（逻辑像素）
  final double brushSize;

  final ValueChanged<MaskDraft> onDraftChanged;

  /// 一次拖拽手势的起止。
  ///
  /// 撤销栈需要它：`onDraftChanged` 在 `onPanUpdate` 里每个采样点都会回调，
  /// 一次涂抹能产生几十份草稿 —— 按回调记栈，点一次撤销只退一个采样点，像没反应。
  /// 画布只在**手势边界**上报，控制器据此把「手势前的草稿」压栈。
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  @override
  State<SelectionCanvas> createState() => _SelectionCanvasState();
}

class _SelectionCanvasState extends State<SelectionCanvas> {
  /// 正在拖的矩形起点（归一化）
  Offset? _rectStart;

  /// 正在拉的角（null = 没在改大小）。
  ///
  /// 原型上写着「拖动选框框住水印，也可以拉右下角改大小」——
  /// 只支持「重新拖一个」是不够的：用户想微调两个像素时，重拖一次必然对不准。
  _Corner? _resizeCorner;

  /// 改大小时**不动**的那个对角（归一化）
  Offset? _resizeAnchor;

  /// 正在画的笔迹（归一化点）。
  ///
  /// 手势中间态留在画布里，松手时才交给上层 —— 见 `setDraft` 的注释。
  List<Offset>? _activePoints;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        final image = widget.imageSize;
        final scale = math.min(area.width / image.width, area.height / image.height);
        final rendered = Size(image.width * scale, image.height * scale);
        final imageRect = Rect.fromLTWH(
          (area.width - rendered.width) / 2,
          (area.height - rendered.height) / 2,
          rendered.width,
          rendered.height,
        );

        Offset toNormalized(Offset local) {
          final dx = (local.dx - imageRect.left) / rendered.width;
          final dy = (local.dy - imageRect.top) / rendered.height;
          return Offset(dx.clamp(0.0, 1.0), dy.clamp(0.0, 1.0));
        }

        /// 归一化笔宽：手指粗细 ÷ 渲染宽度。
        double normalizedWidth() =>
            (widget.brushSize / rendered.width).clamp(0.002, 2.0);

        /// 四个角在**显示坐标**里的位置。改大小的命中判定用它，
        /// 不能用归一化坐标 —— 归一化距离会随图片长宽比变形，横图上的判定区会变扁。
        Map<_Corner, Offset> cornersOf(Rect r) => <_Corner, Offset>{
          _Corner.topLeft: r.topLeft,
          _Corner.topRight: r.topRight,
          _Corner.bottomLeft: r.bottomLeft,
          _Corner.bottomRight: r.bottomRight,
        };

        /// 手指按在哪个角上（22 逻辑像素以内算命中）。
        _Corner? hitCorner(Offset local, Rect displayRect) {
          for (final entry in cornersOf(displayRect).entries) {
            if ((local - entry.value).distance <= 22) return entry.key;
          }
          return null;
        }

        /// 把「正在画的这一笔」同步进草稿。
        ///
        /// [append] 只在 `onPanStart` 时为 true（新起一笔）；
        /// 之后每次移动都是**替换**最后一段。
        /// 用 addingStroke 处理移动事件会让一次拖动变成 N 段笔迹 ——
        /// 真机上表现为「涂抹 53 笔」，画面看不出来（各段完全重叠）。
        MaskDraft draftWithActiveStroke({required bool append}) {
          final pts = _activePoints;
          if (pts == null || pts.isEmpty) return widget.draft;
          final stroke = MaskStroke(
            // ⚠ 必须复制，不能直接传 `pts`。
            //
            // `pts` 是可变列表，后面每次移动都往里加。如果草稿里存的是同一个引用，
            // 那么「上一帧的 draft」和「这一帧的 draft」在 `listEquals` 下**永远相等**
            // （两边读的是同一份内容），`_DraftPainter.shouldRepaint` 就会返回 false，
            // 涂抹过程中看不到实时笔迹，只有抬手后因布局变化才补画一次。
            // 顺带这也让 `MaskStroke` 的 `@immutable` 名副其实。
            points: List<Offset>.of(pts),
            width: normalizedWidth(),
            erase: widget.tool == MaskTool.eraser,
          );
          return append
              ? widget.draft.addingStroke(stroke)
              : widget.draft.replacingLastStroke(stroke);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            widget.onGestureStart?.call();
            final p = toNormalized(details.localPosition);
            switch (widget.tool) {
              case MaskTool.rect:
                // 先看是不是要改大小：按在角上就保留原框，只记下对角当锚点。
                final rect = widget.draft.rect;
                if (rect != null) {
                  final display = Rect.fromLTWH(
                    imageRect.left + rect.left * rendered.width,
                    imageRect.top + rect.top * rendered.height,
                    rect.width * rendered.width,
                    rect.height * rendered.height,
                  );
                  final corner = hitCorner(details.localPosition, display);
                  if (corner != null) {
                    _resizeCorner = corner;
                    _resizeAnchor = corner.opposite(rect);
                    return;
                  }
                }
                // 否则就是拖一个新框。一按下就丢掉旧框，
                // 避免出现「拖到一半还留着上一次的选择」的错觉。
                _rectStart = p;
                widget.onDraftChanged(widget.draft.copyWith(clearRect: true));
              case MaskTool.brush:
              case MaskTool.eraser:
                _activePoints = <Offset>[p];
                widget.onDraftChanged(draftWithActiveStroke(append: true));
            }
          },
          onPanUpdate: (details) {
            final current = toNormalized(details.localPosition);
            switch (widget.tool) {
              case MaskTool.rect:
                final anchor = _resizeAnchor;
                if (_resizeCorner != null && anchor != null) {
                  // 对角固定，被拖的那个角跟着手指 —— 和系统选框的手感一致。
                  widget.onDraftChanged(
                    widget.draft.copyWith(
                      rect: Rect.fromLTRB(
                        math.min(anchor.dx, current.dx),
                        math.min(anchor.dy, current.dy),
                        math.max(anchor.dx, current.dx),
                        math.max(anchor.dy, current.dy),
                      ),
                    ),
                  );
                  return;
                }
                final start = _rectStart;
                if (start == null) return;
                widget.onDraftChanged(
                  widget.draft.copyWith(
                    rect: Rect.fromLTRB(
                      math.min(start.dx, current.dx),
                      math.min(start.dy, current.dy),
                      math.max(start.dx, current.dx),
                      math.max(start.dy, current.dy),
                    ),
                  ),
                );
              case MaskTool.brush:
              case MaskTool.eraser:
                final pts = _activePoints;
                if (pts == null) return;
                // 采样去抖：两点太近就丢掉。手指抖动会让点数暴涨，
                // 而 Mask 是栅格化的 —— 0.002（≈2px@1000）以内的点画不出新东西，
                // 只会让 state 每帧都变、整棵树重建。
                final last = pts.last;
                if ((current - last).distance < 0.002) return;
                pts.add(current);
                widget.onDraftChanged(draftWithActiveStroke(append: false));
            }
          },
          onPanEnd: (_) {
            _rectStart = null;
            _resizeCorner = null;
            _resizeAnchor = null;
            _activePoints = null;
            widget.onGestureEnd?.call();
          },
          onPanCancel: () {
            _rectStart = null;
            _resizeCorner = null;
            _resizeAnchor = null;
            _activePoints = null;
            widget.onGestureEnd?.call();
          },
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: imageRect,
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              Positioned.fromRect(
                rect: imageRect,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _DraftPainter(
                      // 此刻草稿里最后一段就是「正在画的这一笔」，替换是幂等的；
                      // 这里用 append:false 只是为了不变出第 N 段。
                      draft: draftWithActiveStroke(append: false),
                      color: t.flame,
                    ),
                  ),
                ),
              ),
              // 提示语只在「画面下方还有留白」时显示。
              // 画布很矮（横屏 / 分屏）时画面会按高度顶满，这行字就正好压在
              // 要框选的地方 —— 横屏实测见过，字和花瓣叠在一起，反而挡操作。
              if (widget.draft.isEmpty &&
                  _activePoints == null &&
                  (area.height - imageRect.bottom) >= 26)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: IgnorePointer(
                    child: Text(
                      widget.tool == MaskTool.rect
                          ? '拖一个框罩住水印，也可以拉四个角改大小'
                          : '用手指在水印上涂抹，涂到的地方才会被修',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: t.cream.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 把草稿画在图片**显示矩形**内（坐标都在这个矩形里，与图片 1:1 对齐）。
///
/// 预览必须和最终 Mask 的形状一致，否则用户看到「涂成这样」、结果却是「修成那样」。
/// 所以这里和 `MaskComposer._renderMask` 用同一套顺序与覆盖规则：
/// 先矩形、再按顺序叠笔迹，橡皮**用背景色擦**（可视化上等价于挖掉）。
class _DraftPainter extends CustomPainter {
  _DraftPainter({required this.draft, required this.color});

  final MaskDraft draft;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = draft.rect;
    if (rect != null && rect.width > 0 && rect.height > 0) {
      final display = Rect.fromLTRB(
        rect.left * size.width,
        rect.top * size.height,
        rect.right * size.width,
        rect.bottom * size.height,
      );
      canvas.drawRect(
        display,
        Paint()..color = color.withValues(alpha: 0.14),
      );
      canvas.drawRect(
        display,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      // 四个角点：让用户一眼看出这是「框」，不是涂的
      for (final corner in <Offset>[
        display.topLeft,
        display.topRight,
        display.bottomLeft,
        display.bottomRight,
      ]) {
        canvas.drawRect(
          Rect.fromCenter(center: corner, width: 8, height: 8),
          Paint()..color = color,
        );
      }
    }

    if (draft.strokes.isEmpty) return;

    // 橡皮要「擦掉」已画的预览，只有混合模式能做到（画背景色会在图片上留一块实心块）。
    // saveLayer 是必须的：不隔离图层，clear 会把底下整张图一起擦掉。
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in draft.strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = color.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = (stroke.width * size.width).clamp(2.0, size.width)
        ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.srcOver;

      if (stroke.points.length == 1) {
        final p = _toDisplay(stroke.points.first, size);
        canvas.drawPoints(PointMode.points, <Offset>[p], paint);
        continue;
      }
      final path = Path();
      final first = _toDisplay(stroke.points.first, size);
      path.moveTo(first.dx, first.dy);
      for (final p in stroke.points.skip(1)) {
        final d = _toDisplay(p, size);
        path.lineTo(d.dx, d.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  Offset _toDisplay(Offset normalized, Size size) =>
      Offset(normalized.dx * size.width, normalized.dy * size.height);

  @override
  bool shouldRepaint(_DraftPainter old) =>
      old.draft != draft || old.color != color;
}

/// 选框的四个角。
///
/// 单独一个枚举是为了让「拖哪个角、哪个角不动」只能有一处定义 ——
/// 写成 `switch (corner)` 散在 update 里，很容易把对角写反，
/// 表现是「拖右下角，左上角跟着跑」，用户会觉得选框在滑。
enum _Corner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  /// 拖本角时保持不动的对角（归一化坐标）。
  Offset opposite(Rect rect) => switch (this) {
    _Corner.topLeft => rect.bottomRight,
    _Corner.topRight => rect.bottomLeft,
    _Corner.bottomLeft => rect.topRight,
    _Corner.bottomRight => rect.topLeft,
  };
}
