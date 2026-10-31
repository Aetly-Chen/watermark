import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// 图片上的遮罩草稿 —— 用户「框」的和「涂」的东西。
///
/// 为什么不是只有一个 `Rect`：原型上给了四个工具（矩形 / 画笔涂抹 / 橡皮擦 / 清除），
/// 而水印形状千奇百怪（文字水印是斜排的、徽标嵌在复杂纹理里），矩形框大了会把干净背景
/// 一起糊掉。涂抹是这一屏的核心交互，不是附加功能。
///
/// **坐标一律归一化到 0..1**（x 按图宽、y 按图高）。三个理由：
/// 1. 画布是 `BoxFit.contain`，显示尺寸和原图尺寸不一样，存像素就等于把屏幕尺寸焊进数据；
/// 2. Mask 生成时按原图像素乘回去，换设备/换缩放都不会错位；
/// 3. 视频那条链路（`MaskPlan`）同样只吃归一化坐标，两边能共用一套心智模型。
///
/// 笔迹宽度也归一化到**图宽**（不是图高）—— 这样它在像素空间是正圆，
/// 不会在 16:9 的图上被拉成椭圆。
@immutable
class MaskDraft {
  const MaskDraft({this.rect, this.strokes = const <MaskStroke>[]});

  const MaskDraft.empty() : rect = null, strokes = const <MaskStroke>[];

  /// 矩形选框。和涂抹可以**共存**：先用框罩住一大片，再用橡皮擦掉多涂的部分。
  final Rect? rect;

  /// 按顺序叠加：后画的盖住先画的（画笔盖黑、橡皮挖白），和看到的预览一致。
  final List<MaskStroke> strokes;

  /// 有没有**真正要修**的地方。
  ///
  /// 只画了橡皮不算 —— 那等于什么都没涂。这个判断放在这里而不是界面里：
  /// 「开始修复」按钮的可用性、Mask 生成的入参校验必须是同一个标准，
  /// 两处各写一遍迟早分叉（一处允许点、一处抛异常）。
  bool get hasMask {
    final r = rect;
    if (r != null && r.width > 0 && r.height > 0) return true;
    return strokes.any((s) => !s.erase && s.points.isNotEmpty);
  }

  bool get isEmpty => !hasMask;

  MaskDraft copyWith({
    Rect? rect,
    List<MaskStroke>? strokes,
    bool clearRect = false,
  }) => MaskDraft(
    rect: clearRect ? null : (rect ?? this.rect),
    strokes: strokes ?? this.strokes,
  );

  /// 追加一段笔迹。返回新对象（state 是不可变的，就地改会漏掉重建）。
  MaskDraft addingStroke(MaskStroke stroke) => MaskDraft(
    rect: rect,
    strokes: <MaskStroke>[...strokes, stroke],
  );

  /// 用新的笔画**替换最后一段** —— 给「正在画的那一笔」用。
  ///
  /// ⚠ 拖动过程中的每一次 `onPanUpdate` 都必须走这条，不能走 [addingStroke]。
  /// 2026-10-22 真机上抓到过：一次横着涂水印，界面显示「**涂抹 53 笔**」。
  /// 画面看着完全正常（53 段笔迹指向同一个点列表、完全重叠），所以只在计数上露馅；
  /// 代价是 Mask 会把同一条线重复画 53 遍。
  ///
  /// 单测里 `tester.drag` 只产生**一次**移动事件，所以这个 bug 在测试里是隐形的 ——
  /// 必须手动 `startGesture` + 多次 `moveBy` 才复现。
  MaskDraft replacingLastStroke(MaskStroke stroke) {
    if (strokes.isEmpty) return addingStroke(stroke);
    return MaskDraft(
      rect: rect,
      strokes: <MaskStroke>[...strokes.take(strokes.length - 1), stroke],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MaskDraft &&
      other.rect == rect &&
      listEquals(other.strokes, strokes);

  @override
  int get hashCode => Object.hash(rect, Object.hashAll(strokes));

  @override
  String toString() => 'MaskDraft(rect: $rect, strokes: ${strokes.length})';
}

/// 一段笔迹。
///
/// 点是**归一化**的；[width] 是归一化笔宽（相对图宽）。
/// 单点笔迹是合法的 —— 用户点一下就该留下一个圆点，不该要求他先拖出长度。
@immutable
class MaskStroke {
  const MaskStroke({
    required this.points,
    required this.width,
    this.erase = false,
  });

  final List<Offset> points;

  /// 归一化笔宽（直径，相对图宽）。0.02 ≈ 图宽的 2%。
  final double width;

  /// true = 橡皮擦，从已有遮罩里挖掉。
  final bool erase;

  bool get isEmpty => points.isEmpty;

  MaskStroke addingPoint(Offset p) =>
      MaskStroke(points: <Offset>[...points, p], width: width, erase: erase);

  @override
  bool operator ==(Object other) =>
      other is MaskStroke &&
      other.erase == erase &&
      other.width == width &&
      listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(erase, width, Object.hashAll(points));
}

/// 当前选中的工具。原型上就是这四个，`clear` 不是「工具」而是动作，
/// 所以放在页面里直接调 `clearDraft()`，不进这里。
enum MaskTool {
  rect('矩形'),
  brush('涂抹'),
  eraser('橡皮');

  const MaskTool(this.label);

  final String label;
}
