import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../core/processing/processing_error.dart';
import '../domain/mask_draft.dart';

/// 送进 native 前的两个文件。
class PreparedInput {
  const PreparedInput({
    required this.inputPath,
    required this.maskPath,
    required this.width,
    required this.height,
  });

  final String inputPath;
  final String maskPath;
  final int width;
  final int height;
}

/// 把「用户看到的图 + 框选/涂抹」翻译成 native 能直接吃的一对文件。
///
/// 这里做两件事，都有明确理由：
///
/// 1. **把输入重新编码成 PNG**。相机 JPEG 带 EXIF 方向，OpenCV 的 `imread` 不认 EXIF，
///    而 Flutter 显示时是认的 —— 两边一旦不一致，Mask 就会整个错位。
///    直接从「Flutter 已经解码好的位图」再编码，等于把用户看到的像素原样交给引擎，
///    方向问题在源头消掉，native 不需要知道 EXIF 这回事。
/// 2. **生成与原图同尺寸的二值 Mask**。Mask 不做缩放、不按显示尺寸存，
///    永远和输入 1:1 —— 尺寸对不上是这类实现最常见的错位来源。
class MaskComposer {
  const MaskComposer._();

  static Future<PreparedInput> prepare({
    required Uint8List sourceBytes,
    required MaskDraft draft,
    required Directory workDir,
    required String taskId,
  }) async {
    if (draft.isEmpty) {
      throw const ProcessingException(
        ProcessingErrorCode.invalidMask,
        detail: '还没有框选或涂抹要修的地方',
      );
    }

    final codec = await ui.instantiateImageCodec(sourceBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width;
    final height = image.height;

    try {
      final inputFile = File('${workDir.path}/in_$taskId.png');
      await inputFile.writeAsBytes(
        await _encode(image, width, height),
        flush: true,
      );

      final maskFile = File('${workDir.path}/mask_$taskId.png');
      final mask = await _renderMask(width, height, draft);
      try {
        await maskFile.writeAsBytes(await _encode(mask, width, height), flush: true);
      } finally {
        mask.dispose();
      }

      return PreparedInput(
        inputPath: inputFile.path,
        maskPath: maskFile.path,
        width: width,
        height: height,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  /// 只渲染遮罩（不碰源图），按给定的像素尺寸输出 PNG。
  ///
  /// 视频没有「一张源图」可以 instantiateImageCodec —— 它的画布是封面帧，
  /// 尺寸由探测给出。所以这里直接按尺寸画，坐标仍是归一化的那一套。
  static Future<Uint8List> renderMaskPng({
    required int width,
    required int height,
    required MaskDraft draft,
  }) async {
    if (draft.isEmpty) {
      throw const ProcessingException(
        ProcessingErrorCode.invalidMask,
        detail: '还没有框选或涂抹要修的地方',
      );
    }
    final mask = await _renderMask(width, height, draft);
    try {
      return await _encode(mask, width, height);
    } finally {
      mask.dispose();
    }
  }

  /// 位图 → PNG 字节
  static Future<Uint8List> _encode(ui.Image image, int width, int height) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw const ProcessingException(
        ProcessingErrorCode.decodeFailed,
        detail: 'PNG 编码失败',
      );
    }
    return byteData.buffer.asUint8List();
  }

  /// 黑底 + 白块。白 = 需要修复的区域。
  ///
  /// 绘制顺序就是用户的操作顺序：先框/先涂的在下，后画的在上。
  /// **橡皮擦是「用黑色盖掉」，不是 `BlendMode.clear`** —— 理由很实际：
  /// 输出要交给 OpenCV，而 `imread` 会把带 alpha 的 PNG 压成 BGR，
  /// 透明像素的 RGB 是 0（黑），结果和画黑一样，但中间多了一层「alpha 语义」的猜疑。
  /// 直接画黑，读到的是什么就是什么。
  static Future<ui.Image> _renderMask(
    int width,
    int height,
    MaskDraft draft,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = ui.Size(width.toDouble(), height.toDouble());

    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF000000),
    );

    const white = ui.Color(0xFFFFFFFF);
    const black = ui.Color(0xFF000000);

    final rect = draft.rect;
    if (rect != null && rect.width > 0 && rect.height > 0) {
      // 归一化 → 像素，并夹到图内，避免用户把框拖出画布后出现负坐标
      final pixelRect = ui.Rect.fromLTRB(
        (rect.left.clamp(0.0, 1.0) * width),
        (rect.top.clamp(0.0, 1.0) * height),
        (rect.right.clamp(0.0, 1.0) * width),
        (rect.bottom.clamp(0.0, 1.0) * height),
      );
      if (pixelRect.width < 2 || pixelRect.height < 2) {
        throw const ProcessingException(
          ProcessingErrorCode.invalidMask,
          detail: '选区太小（<2px），无法生成有效 Mask',
        );
      }
      canvas.drawRect(pixelRect, ui.Paint()..color = white);
    }

    for (final stroke in draft.strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = ui.Paint()
        ..color = stroke.erase ? black : white
        ..style = ui.PaintingStyle.stroke
        // 圆头圆角：单点笔迹（用户只是点了一下）也能落下一个圆点，
        // 否则「点一下没反应」又是一次「看着能点其实没做」。
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..strokeWidth = (stroke.width * width).clamp(1.0, width.toDouble());

      final path = ui.Path();
      final first = _toPixel(stroke.points.first, width, height);
      path.moveTo(first.dx, first.dy);
      if (stroke.points.length == 1) {
        // 零长度线段画不出来 —— 用 drawPoints 单独处理单点
        canvas.drawPoints(ui.PointMode.points, <ui.Offset>[first], paint);
        continue;
      }
      for (final p in stroke.points.skip(1)) {
        final pixel = _toPixel(p, width, height);
        path.lineTo(pixel.dx, pixel.dy);
      }
      canvas.drawPath(path, paint);
    }

    return recorder.endRecording().toImage(width, height);
  }

  static ui.Offset _toPixel(ui.Offset normalized, int width, int height) =>
      ui.Offset(
        normalized.dx.clamp(0.0, 1.0) * width,
        normalized.dy.clamp(0.0, 1.0) * height,
      );
}
