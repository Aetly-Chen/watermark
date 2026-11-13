import 'dart:math' as math;
import 'dart:typed_data';

import 'mask_draft.dart';

/// 估算遮罩覆盖了画面的多少 —— 用来在**修复之前**就告诉用户「这个框太大了」。
///
/// ## 为什么要它
///
/// 现在的填充是 OpenCV 的 `inpaint(TELEA)`，它是**扩散**算法：只把洞边界
/// 的颜色沿等照度线往里推，不会造纹理。洞小的时候边界信息够用；洞一大，
/// 填出来的必然是一片平滑色团 —— 用户看到的就是「一块糊掉的地方」。
///
/// 实测（960×540，同一帧贴同一个水印）：
///
/// | 掩膜 | 占画面 | PSNR | 纹理保持 |
/// |---|---|---|---|
/// | 拖一个矩形框 | 16.4% | 12.05 | 12% |
/// | 贴着字涂 | 3.4% | 25.47 | 76% |
///
/// 也就是说**掩膜大小是主要矛盾**，而这件事在按「开始修复」之前就能算出来。
/// 算出来却不提示，等于让用户踩完坑才在结果页看到解释。
///
/// ## 为什么是「估算」而不是精确
///
/// 精确的 Mask 是原生侧按原图像素栅格化的（`VideoProcessor.buildMask`）。
/// 这里只需要判断「有没有超过 12%」，没必要为此多跑一趟 JNI；在归一化坐标上
/// 用一张 240 宽的格子铺一遍，误差在 1% 以内，够用且是纯 Dart、可单测。
double maskCoverage(
  MaskDraft draft, {
  required double aspect,
  int gridWidth = 240,
}) {
  if (!draft.hasMask) return 0;

  // 虚拟像素空间：宽 1000，高按画幅比推。这样格子是正方形，
  // 圆头笔迹不会被拉成椭圆（归一化坐标里 x、y 的单位长度不一样）。
  const w = 1000.0;
  final h = w / (aspect.isFinite && aspect > 0 ? aspect : 1.0);
  final cell = w / gridWidth;
  final gw = gridWidth;
  final gh = math.max(1, (h / cell).round());
  final grid = Uint8List(gw * gh);

  int cellOf(double v, int n) => (v / cell).floor().clamp(0, n - 1);

  void stamp(double px, double py, double rad, bool erase) {
    final x0 = cellOf(px - rad, gw);
    final x1 = cellOf(px + rad, gw);
    final y0 = cellOf(py - rad, gh);
    final y1 = cellOf(py + rad, gh);
    final rad2 = rad * rad;
    for (var j = y0; j <= y1; j++) {
      final cy = (j + 0.5) * cell;
      for (var i = x0; i <= x1; i++) {
        final cx = (i + 0.5) * cell;
        final dx = cx - px;
        final dy = cy - py;
        if (dx * dx + dy * dy <= rad2) {
          grid[j * gw + i] = erase ? 0 : 1;
        }
      }
    }
  }

  final r = draft.rect;
  if (r != null && r.width > 0 && r.height > 0) {
    final x0 = cellOf(r.left * w, gw);
    final x1 = cellOf(r.right * w, gw);
    final y0 = cellOf(r.top * h, gh);
    final y1 = cellOf(r.bottom * h, gh);
    for (var j = y0; j <= y1; j++) {
      for (var i = x0; i <= x1; i++) {
        grid[j * gw + i] = 1;
      }
    }
  }

  // 后画的盖住先画的：画笔填 1、橡皮抹 0 —— 与 MaskDraft 的叠放规则一致
  for (final stroke in draft.strokes) {
    if (stroke.points.isEmpty) continue;
    final rad = stroke.width / 2 * w;
    final step = cell / 2;
    var prev = stroke.points.first;
    stamp(prev.dx * w, prev.dy * h, rad, stroke.erase);
    for (final p in stroke.points.skip(1)) {
      final from = prev;
      final dx = (p.dx - from.dx) * w;
      final dy = (p.dy - from.dy) * h;
      final dist = math.sqrt(dx * dx + dy * dy);
      final n = math.max(1, (dist / step).ceil());
      for (var k = 1; k <= n; k++) {
        stamp(from.dx * w + dx * k / n, from.dy * h + dy * k / n, rad, stroke.erase);
      }
      prev = p;
    }
  }

  var on = 0;
  for (final v in grid) {
    if (v != 0) on++;
  }
  return on / (gw * gh);
}
