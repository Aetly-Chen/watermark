import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/processing/processing_error.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';
import 'package:watermark_remover/features/image_editor/infrastructure/mask_composer.dart';

/// 这一层最容易出错、也最难靠肉眼发现：归一化坐标 → 像素的映射错了，
/// 表现是「修了一块位置偏掉的地方」，看着像算法问题，其实是坐标问题。
/// 所以用真实 PNG 走一遍，逐像素断言。
void main() {
  // 这些用例调的是真实的图片解码与栅格化（dart:ui），必须跑在真异步环境里。
  // 用 testWidgets 会被 FakeAsync 卡住 —— 表现为「did not complete」，不是断言失败。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('wm_mask_test');
  });

  tearDown(() async {
    if (workDir.existsSync()) {
      await workDir.delete(recursive: true);
    }
  });

  test('Mask 与原图同尺寸，白块位置精确对应归一化选区', () async {
    const width = 100;
    const height = 60;
    final source = await _solidPng(width, height);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      // x: 25..75, y: 30..45
      draft: const MaskDraft(rect: ui.Rect.fromLTWH(0.25, 0.5, 0.5, 0.25)),
      workDir: workDir,
      taskId: 'unit',
    );

    expect(prepared.width, width);
    expect(prepared.height, height);

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    final mask = await _decode(maskBytes);

    expect(mask.width, width, reason: 'Mask 必须与原图同尺寸');
    expect(mask.height, height);

    // 框内
    expect(await _red(maskBytes, 50, 37), 255, reason: '选区中心必须是白');
    expect(await _red(maskBytes, 25, 30), 255, reason: '左上角内沿是白');
    expect(await _red(maskBytes, 74, 44), 255, reason: '右下角内沿是白');
    // 框外
    expect(await _red(maskBytes, 5, 5), 0, reason: '左上角外必须是黑');
    expect(await _red(maskBytes, 90, 55), 0, reason: '右下角外必须是黑');
    expect(await _red(maskBytes, 50, 5), 0, reason: '选区上方是黑');

    // 输入图也必须是可解码的 PNG，且尺寸一致（native 靠这个对齐）
    final input = await _decode(await File(prepared.inputPath).readAsBytes());
    expect(input.width, width);
    expect(input.height, height);
  });

  test('空选区直接抛 invalid_mask，不会产出一张全黑 Mask', () async {
    final source = await _solidPng(20, 20);

    await expectLater(
      MaskComposer.prepare(
        sourceBytes: source,
        draft: const MaskDraft.empty(),
        workDir: workDir,
        taskId: 'unit-empty',
      ),
      throwsA(
        isA<ProcessingException>().having(
          (e) => e.code,
          'code',
          ProcessingErrorCode.invalidMask,
        ),
      ),
    );
  });

  test('选区被拖出画布时会夹到图内，不产生负坐标', () async {
    const width = 40;
    const height = 40;
    final source = await _solidPng(width, height);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      // 故意越界：右下角到 1.4
      draft: const MaskDraft(rect: ui.Rect.fromLTRB(0.5, 0.5, 1.4, 1.4)),
      workDir: workDir,
      taskId: 'unit-clamp',
    );

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    expect(await _red(maskBytes, 39, 39), 255, reason: '越界部分应夹到右下角');
    expect(await _red(maskBytes, 5, 5), 0);
  });

  // ── 下面是「涂抹」这条新链路 ──
  // 涂抹是核心交互（原型上的「画笔涂抹」），它把归一化坐标 + 归一化笔宽
  // 变成像素圆点/线段。这里逐像素断言，别靠眼睛看截图。

  test('单点笔迹：点一下就落下一个圆点', () async {
    const width = 100;
    const height = 100;
    final source = await _solidPng(width, height);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      // 笔宽 0.2（图宽的 20% → 20px），点心在正中
      draft: const MaskDraft(
        strokes: <MaskStroke>[
          MaskStroke(points: <Offset>[Offset(0.5, 0.5)], width: 0.2),
        ],
      ),
      workDir: workDir,
      taskId: 'unit-dot',
    );

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    expect(await _red(maskBytes, 50, 50), 255, reason: '圆心是白');
    expect(await _red(maskBytes, 53, 50), 255, reason: '半径内是白');
    expect(
      await _red(maskBytes, 50, 53),
      255,
      reason: '竖直方向也必须是白 —— 笔宽按图宽归一化，圆不能被拉成椭圆',
    );
    expect(await _red(maskBytes, 50, 66), 0, reason: '圆外是黑');
    expect(await _red(maskBytes, 10, 10), 0);
  });

  test('线段笔迹：两端与中点都在 Mask 里', () async {
    final source = await _solidPng(100, 100);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      draft: const MaskDraft(
        strokes: <MaskStroke>[
          MaskStroke(
            points: <Offset>[Offset(0.2, 0.2), Offset(0.8, 0.8)],
            width: 0.06,
          ),
        ],
      ),
      workDir: workDir,
      taskId: 'unit-line',
    );

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    expect(await _red(maskBytes, 20, 20), 255, reason: '起点');
    expect(await _red(maskBytes, 50, 50), 255, reason: '中点');
    expect(await _red(maskBytes, 80, 80), 255, reason: '终点');
    expect(await _red(maskBytes, 80, 20), 0, reason: '不在线上的不该白');
  });

  test('橡皮：盖掉涂抹过的地方，没涂过的地方一动不动', () async {
    final source = await _solidPng(100, 100);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      draft: const MaskDraft(
        strokes: <MaskStroke>[
          // 先横着涂一长条
          MaskStroke(
            points: <Offset>[Offset(0.1, 0.5), Offset(0.9, 0.5)],
            width: 0.2,
          ),
          // 再从中间擦掉一段
          MaskStroke(
            points: <Offset>[Offset(0.5, 0.5)],
            width: 0.3,
            erase: true,
          ),
        ],
      ),
      workDir: workDir,
      taskId: 'unit-erase',
    );

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    expect(await _red(maskBytes, 50, 50), 0, reason: '擦掉之后必须是黑（不修）');
    expect(await _red(maskBytes, 20, 50), 255, reason: '没擦到的部分还在');
    expect(await _red(maskBytes, 80, 50), 255);
  });

  test('框 + 涂抹可以共存：框在下面，涂抹叠在上面', () async {
    final source = await _solidPng(100, 100);

    final prepared = await MaskComposer.prepare(
      sourceBytes: source,
      draft: const MaskDraft(
        rect: Rect.fromLTRB(0.1, 0.1, 0.5, 0.5),
        strokes: <MaskStroke>[
          MaskStroke(points: <Offset>[Offset(0.8, 0.8)], width: 0.1),
        ],
      ),
      workDir: workDir,
      taskId: 'unit-both',
    );

    final maskBytes = await File(prepared.maskPath).readAsBytes();
    expect(await _red(maskBytes, 30, 30), 255, reason: '框内');
    expect(await _red(maskBytes, 80, 80), 255, reason: '涂抹处');
    expect(await _red(maskBytes, 70, 20), 0, reason: '两边都没盖到的仍是黑');
  });

  test('只画了橡皮 → 抛 invalid_mask（否则会送一张全黑 Mask 给 native）', () async {
    final source = await _solidPng(20, 20);

    await expectLater(
      MaskComposer.prepare(
        sourceBytes: source,
        draft: const MaskDraft(
          strokes: <MaskStroke>[
            MaskStroke(
              points: <Offset>[Offset(0.5, 0.5)],
              width: 0.1,
              erase: true,
            ),
          ],
        ),
        workDir: workDir,
        taskId: 'unit-erase-only',
      ),
      throwsA(
        isA<ProcessingException>().having(
          (e) => e.code,
          'code',
          ProcessingErrorCode.invalidMask,
        ),
      ),
    );
  });
}

Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<int> _red(Uint8List png, int x, int y) async {
  final image = await _decode(png);
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final offset = (y * image.width + x) * 4;
    return raw!.getUint8(offset);
  } finally {
    image.dispose();
  }
}
