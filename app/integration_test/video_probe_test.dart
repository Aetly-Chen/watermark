import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/video_probe.dart';

/// 真机验证视频探测层：元数据、旋转换算、封面帧。
///
/// 为什么这些断言值得写：视频链路后面所有坐标（Mask、追踪、逐帧修复）都建立在
/// 「哪张帧、多大、正不正」这三个问题上。这里错了，后面每一步都会歪，而画面上
/// 看起来只是「修得不准」，极难回溯。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例视频：能读到元数据，封面帧方向与显示尺寸一致', (tester) async {
    final data = await rootBundle.load('assets/samples/sample.mp4');
    final dir = await getTemporaryDirectory();
    final video = File('${dir.path}/sample_itest.mp4');
    await video.writeAsBytes(data.buffer.asUint8List(), flush: true);

    const probe = VideoProbe();

    final meta = await probe.probe(video.path);
    debugPrint(
      'VITEST_META ${meta.width}x${meta.height} rot=${meta.rotation} '
      'display=${meta.displayWidth}x${meta.displayHeight} '
      'dur=${meta.duration.inMilliseconds}ms audio=${meta.hasAudio} bytes=${meta.sizeBytes}',
    );

    expect(meta.width, greaterThan(0), reason: '编码宽度必须读得到');
    expect(meta.height, greaterThan(0));
    expect(meta.duration.inMilliseconds, greaterThan(0), reason: '时长必须 > 0');
    expect(meta.sizeBytes, greaterThan(0));
    expect(meta.path, isNotEmpty);

    if (meta.isRotated) {
      expect(meta.displayWidth, meta.height, reason: '90/270 度要把宽高换过来');
      expect(meta.displayHeight, meta.width);
    } else {
      expect(meta.displayWidth, meta.width);
      expect(meta.displayHeight, meta.height);
    }

    final frame = await probe.extractFrame(
      path: video.path,
      outputPath: '${dir.path}/poster_itest.png',
    );
    final file = File(frame.path);
    expect(file.existsSync(), isTrue, reason: '封面帧必须落盘');
    expect(file.lengthSync(), greaterThan(1000), reason: '封面帧不该是空图');
    expect(frame.width, greaterThan(0));
    expect(frame.height, greaterThan(0));

    final longEdge = frame.width > frame.height ? frame.width : frame.height;
    expect(longEdge, lessThanOrEqualTo(1080), reason: '封面帧最长边要压到 1080 以内');

    // 关键断言：封面帧的宽高比要和「用户看到的尺寸」一致，否则框选会歪 90°
    final frameRatio = frame.width / frame.height;
    final displayRatio = meta.displayWidth / meta.displayHeight;
    expect(
      (frameRatio - displayRatio).abs(),
      lessThan(0.02),
      reason: '封面方向必须与显示尺寸一致（frame=$frameRatio display=$displayRatio）',
    );

    // 再验一次：这张 PNG 能被 Flutter 解码（说明不是写坏的半截文件）
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final decoded = (await codec.getNextFrame()).image;
    debugPrint(
      'VITEST_FRAME ${frame.width}x${frame.height} ${file.lengthSync()}B '
      'decoded=${decoded.width}x${decoded.height} ${frame.elapsed.inMilliseconds}ms',
    );
    expect(decoded.width, frame.width, reason: '回传尺寸必须等于真实解码尺寸');
    expect(decoded.height, frame.height);
    decoded.dispose();
    codec.dispose();
  });
}
