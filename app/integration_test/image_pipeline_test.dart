import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/gallery_saver.dart';
import 'package:watermark_remover/core/processing/local_basic_image_processor.dart';
import 'package:watermark_remover/core/processing/mask_plan.dart';
import 'package:watermark_remover/core/processing/processing_request.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';
import 'package:watermark_remover/features/image_editor/infrastructure/mask_composer.dart';

/// 真机集成测试：不经过 UI，直接打穿「Dart 组 Mask → 平台通道 → Kotlin + OpenCV → 回传文件」。
///
/// 为什么不用点屏幕：本机 adb 的触摸注入会被系统丢事件/延迟投递，屏幕上的状态无法作为证据。
/// 这个测试断言的是像素本身，比截图可靠。
///
/// 跑法：
///   flutter test integration_test/image_pipeline_test.dart -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例图 → Mask → OpenCV 修复：输出尺寸一致，且水印区域像素确实被改写', (
    tester,
  ) async {
    final data = await rootBundle.load('assets/samples/cafe.jpg');
    final sourceBytes = data.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    const taskId = 'itest';

    // 示例图右下角是「© THE COZY CORNER CAFE」，实测只有 6 px 高：
    // 亮像素（>90）落在 x[1043,1189] y[884,889]。框要往左多让一点才能盖住开头的 ©。
    //
    // 注意：assets/cafe-clean.png **不能**当基准图 —— 它自己就带着同一行水印，
    // 且与原图的差异区（y832~878 的暗区）根本不在文字上。证据见 README。
    const watermarkBox = ui.Rect.fromLTRB(0.855, 0.978, 0.998, 0.997);
    final prepared = await MaskComposer.prepare(
      sourceBytes: sourceBytes,
      draft: const MaskDraft(rect: watermarkBox),
      workDir: dir,
      taskId: taskId,
    );

    final result = await LocalBasicImageProcessor().process(
      ProcessingRequest(
        taskId: taskId,
        inputPath: prepared.inputPath,
        outputPath: '${dir.path}/out_$taskId.png',
        mediaKind: MediaKind.image,
        plan: MaskPlan.fixed(maskPath: prepared.maskPath),
      ),
    );

    expect(File(result.outputPath).existsSync(), isTrue, reason: '必须落盘');
    expect(result.outputWidth, prepared.width, reason: '输出宽度必须与输入一致');
    expect(result.outputHeight, prepared.height, reason: '输出高度必须与输入一致');
    expect(result.elapsed.inMilliseconds, greaterThan(0));

    final before = await _decode(await File(prepared.inputPath).readAsBytes());
    final after = await _decode(await File(result.outputPath).readAsBytes());

    // 在水印区域内扫一块，统计被改写的像素数
    var changed = 0;
    final yStart = (after.height * watermarkBox.top).floor();
    final xStart = (after.width * watermarkBox.left).floor();
    final yEnd = (after.height * watermarkBox.bottom).ceil().clamp(0, after.height - 2);
    final xEnd = (after.width * watermarkBox.right).ceil().clamp(0, after.width - 2);
    for (var y = yStart; y < yEnd; y++) {
      for (var x = xStart; x < xEnd; x++) {
        final offset = (y * after.width + x) * 4;
        final dr = before.rgba[offset] - after.rgba[offset];
        final dg = before.rgba[offset + 1] - after.rgba[offset + 1];
        final db = before.rgba[offset + 2] - after.rgba[offset + 2];
        if (dr.abs() + dg.abs() + db.abs() > 30) changed++;
      }
    }

    debugPrint(
      'ITEST_OK path=${result.outputPath} '
      'size=${result.outputWidth}x${result.outputHeight} '
      'elapsed=${result.elapsed.inMilliseconds}ms changedPixels=$changed',
    );

    expect(
      changed,
      greaterThan(250),
      reason: '水印区域应当有成片像素被改写，实际 $changed',
    );

    // 第二段：把结果写进相册。这一步顺带解决「测试包被卸载、产物取不回来」的问题 ——
    // 落到 Pictures/ 下的文件可以用 adb pull 直接拉回本地做质量对照。
    final uri = await const GallerySaver().save(
      sourcePath: result.outputPath,
      displayName: 'itest_cafe.png',
    );
    debugPrint('ITEST_SAVED uri=$uri');

    expect(uri, startsWith('content://media/'), reason: '应当返回 MediaStore URI');
  });

  testWidgets('大框 + 框内细分：Mask 收窄了，水印仍被修掉（但背景涂抹没解决）', (tester) async {
    final sourceBytes = (await rootBundle.load('assets/samples/cafe.jpg')).buffer.asUint8List();
    final dir = await getTemporaryDirectory();

    // 故意给一个大十倍的框：这是 v1 会把整块背景糊成棕色的那个案例
    const bigBox = ui.Rect.fromLTRB(0.62, 0.93, 1.0, 1.0);
    const taskId = 'itest_bigbox';
    final prepared = await MaskComposer.prepare(
      sourceBytes: sourceBytes,
      draft: const MaskDraft(rect: bigBox),
      workDir: dir,
      taskId: taskId,
    );

    final result = await LocalBasicImageProcessor().process(
      ProcessingRequest(
        taskId: taskId,
        inputPath: prepared.inputPath,
        outputPath: '${dir.path}/out_$taskId.png',
        mediaKind: MediaKind.image,
        plan: MaskPlan.fixed(maskPath: prepared.maskPath),
        // 显式打开实验开关。**默认是关的** —— 见 ProcessingRequest.refineMask 的实测记录。
        refineMask: true,
      ),
    );

    final before = await _decode(await File(prepared.inputPath).readAsBytes());
    final after = await _decode(await File(result.outputPath).readAsBytes());

    // 水印真正占的条带（实测过的位置），落在框外/框内的都算
    final stripTop = (after.height * 0.978).floor();
    final stripLeft = (after.width * 0.855).floor();
    final stripBottom = (after.height * 0.997).ceil();
    final stripRight = (after.width * 0.998).ceil();

    var changedInStrip = 0;
    var changedOutsideStrip = 0;
    for (var y = (after.height * 0.93).floor(); y < after.height - 2; y++) {
      for (var x = (after.width * 0.62).floor(); x < after.width - 2; x++) {
        final offset = (y * after.width + x) * 4;
        final d =
            (before.rgba[offset] - after.rgba[offset]).abs() +
            (before.rgba[offset + 1] - after.rgba[offset + 1]).abs() +
            (before.rgba[offset + 2] - after.rgba[offset + 2]).abs();
        if (d <= 30) continue;
        final inStrip =
            y >= stripTop && y < stripBottom && x >= stripLeft && x < stripRight;
        if (inStrip) {
          changedInStrip++;
        } else {
          changedOutsideStrip++;
        }
      }
    }

    expect(changedInStrip, greaterThan(200), reason: '细分不能把水印笔画一起删掉');

    // 这里**不断言** outsideStrip 变小 —— 实测「细分前后都是 3356」，见下方 debugPrint 与
    // ProcessingRequest.refineMask 的记录。留这个用例的价值是：一旦换成文字级检测，
    // 同一组数字就能直接对比，不用重搭实验。
    debugPrint(
      'ITEST_BIGBOX inStrip=$changedInStrip outsideStrip=$changedOutsideStrip '
      'elapsed=${result.elapsed.inMilliseconds}ms',
    );

    // 存相册，方便 adb pull 回来目视
    await const GallerySaver().save(
      sourcePath: result.outputPath,
      displayName: 'itest_cafe_bigbox.png',
    );
  });
}

Future<({int width, int height, Uint8List rgba})> _decode(
  Uint8List png,
) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return (
      width: image.width,
      height: image.height,
      rgba: raw!.buffer.asUint8List(),
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}
