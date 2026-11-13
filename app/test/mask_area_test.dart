import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_area.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';

/// 遮罩覆盖率估算。
///
/// 这个数只用来判断「是不是大到该提示用户」，所以要求是**别离谱**：
/// 相对误差 ±10% 以内（阈值 12%，判定边界附近才需要更准）。
/// 但「空就是 0」「整屏就是 1」这类边界必须是硬约束 —— 那些报错会让提示乱弹。
void main() {
  const aspect169 = 16 / 9;

  test('空草稿 = 0（只画橡皮也算空）', () {
    expect(maskCoverage(const MaskDraft.empty(), aspect: aspect169), 0);

    const onlyEraser = MaskDraft(
      strokes: <MaskStroke>[
        MaskStroke(points: <Offset>[Offset(0.1, 0.1), Offset(0.9, 0.9)], width: 0.2, erase: true),
      ],
    );
    expect(maskCoverage(onlyEraser, aspect: aspect169), 0);
  });

  test('铺满整幅 = 1', () {
    const full = MaskDraft(rect: Rect.fromLTRB(0, 0, 1, 1));
    expect(maskCoverage(full, aspect: aspect169), closeTo(1.0, 0.01));
  });

  test('半分之一的矩形 = 25%（与画幅比无关）', () {
    const quarter = MaskDraft(rect: Rect.fromLTRB(0.25, 0.25, 0.75, 0.75));
    for (final aspect in <double>[16 / 9, 9 / 16, 1, 4 / 3]) {
      expect(
        maskCoverage(quarter, aspect: aspect),
        closeTo(0.25, 0.02),
        reason: 'aspect=$aspect 下跑偏了',
      );
    }
  });

  test('复现用户那次：376×225 的框放在 960×540 上 ≈ 16.4%', () {
    // 真实的遮罩占比由原生算（buildMask），这里是「修复前」的估算，
    // 两者对同一几何应当吻合 —— 差太多就说明估算口径错了。
    const draft = MaskDraft(
      rect: Rect.fromLTRB(376 / 960, 130 / 540, 752 / 960, 355 / 540),
    );
    expect(maskCoverage(draft, aspect: 960 / 540), closeTo(0.1644, 0.02));
  });

  test('一条横穿的笔迹 ≈ 长度 × 笔宽', () {
    const line = MaskDraft(
      strokes: <MaskStroke>[
        MaskStroke(points: <Offset>[Offset(0.0, 0.5), Offset(1.0, 0.5)], width: 0.04),
      ],
    );
    // 笔宽按**图宽**归一化：横穿一条的面积 = 长(占宽比例) × 笔宽 × 画幅比
    //   = 1.0 × 0.04 × (16/9) ≈ 0.071
    // 第一版我按 0.04 写，红了 —— 那是「图是正方形」才会有的数。
    expect(
      maskCoverage(line, aspect: aspect169),
      closeTo(0.04 * aspect169, 0.01),
      reason: '这条同时验了 aspect 有没有真的进到面积换算里',
    );
  });

  test('橡皮真的会挖掉', () {
    const painted = MaskDraft(strokes: <MaskStroke>[
      MaskStroke(points: <Offset>[Offset(0.0, 0.5), Offset(1.0, 0.5)], width: 0.2),
    ]);
    const erased = MaskDraft(strokes: <MaskStroke>[
      MaskStroke(points: <Offset>[Offset(0.0, 0.5), Offset(1.0, 0.5)], width: 0.2),
      MaskStroke(points: <Offset>[Offset(0.2, 0.5), Offset(0.8, 0.5)], width: 0.2, erase: true),
    ]);
    final a = maskCoverage(painted, aspect: aspect169);
    final b = maskCoverage(erased, aspect: aspect169);
    expect(b, lessThan(a));
    // 挖掉中间 60%，大致剩两端的圆头
    expect(b, lessThan(a * 0.5));
  });

  test('画幅比极端时也不会崩（1:100 的细长条）', () {
    const d = MaskDraft(rect: Rect.fromLTRB(0, 0, 1, 0.02));
    final v = maskCoverage(d, aspect: 100);
    expect(v, inInclusiveRange(0.0, 1.0));
  });
}
