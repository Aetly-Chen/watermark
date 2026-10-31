import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/video_probe.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';

/// 旋转分支（`setOrientationHint` + `mapMaskToFrame`）的真机验证。
///
/// 这条分支写了很久但**一次都没在真机上跑过** —— 素材一直是 `rotation=0`，
/// 而竖拍视频恰恰是手机上的多数。现在用自造素材补上。
///
/// ## 怎么做到「不猜旋转方向」
///
/// 「rotation=90 到底是顺时针还是逆时针」这件事，容器矩阵的符号约定、
/// `MediaMetadataRetriever` 是否已经替我们转过、`postRotate` 的方向，
/// 三处都能踩空。所以测试**不去推理方向**：
///
/// 1. 素材里画了一个已知位置的红块（帧坐标 `(100,100)-(300,200)`，960×540）；
/// 2. 用 App 自己的 `extractFrame` 取「正向化之后」的画面 —— 这就是用户看到的；
/// 3. 在画面里**找出红块的实际像素位置**，把它当作框选区域传进去；
/// 4. 修完再取一帧，红块必须几乎消失。
///
/// 第 3 步是关键：框选区域来自「实际渲染出来的画面」，而不是我算出来的坐标。
/// 这样 `mapMaskToFrame` 只要映射方向错了，红块就会原样留着，断言必挂。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const repairer = VideoRepairer();
  const probe = VideoProbe();

  testWidgets('旋转 90° 的那一帧：Mask 必须落在红块上', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materialize(dir, 'assets/samples/motion_rot90.mp4', 'rot90.mp4');
    final out = File('${dir.path}/rot90_out.mp4');
    if (out.existsSync()) out.deleteSync();

    final meta = await probe.probe(video.path);
    debugPrint(
      'VTEST_ROT probe 编码=${meta.width}x${meta.height} rot=${meta.rotation} '
      '显示=${meta.displayWidth}x${meta.displayHeight} '
      'dur=${meta.duration.inMilliseconds}ms',
    );

    // ⚠ 同一个 tkhd 矩阵，ffmpeg 报 "rotation of 90" 而 Android 报 270 ——
    // 两边的符号约定相反（实测，不是推测）。所以这里只断「是 90/270 这一类」，
    // 方向对不对交给最后那条「红块必须消失」的断言，它不依赖任何约定。
    expect(
      meta.rotation,
      anyOf(90, 270),
      reason: '容器里的显示矩阵没被读出来，rot=${meta.rotation}',
    );
    expect(
      meta.displayHeight,
      greaterThan(meta.displayWidth),
      reason: '旋转后显示应该是竖的，实际 ${meta.displayWidth}x${meta.displayHeight}',
    );

    // 1) 取正向化之后的画面（用户看到的那一版）
    final inFrame = await probe.extractFrame(
      path: video.path,
      outputPath: '${dir.path}/rot_in.png',
      position: Duration.zero,
    );
    final inImg = img.decodeImage(await File(inFrame.path).readAsBytes());
    if (inImg == null) throw StateError('输入帧解码失败');

    // 2) 在画面里找红块 —— 不假设它在哪
    final red = _redBox(inImg);
    debugPrint(
      'VTEST_ROT frame=${inImg.width}x${inImg.height} '
      '红块=${red == null ? "没找到" : "(x ${red[0]}..${red[2]}, y ${red[1]}..${red[3]})"}',
    );
    expect(red, isNotNull, reason: '抽出来的画面里找不到红块，素材或抽帧有问题');
    expect(inImg.width, lessThan(inImg.height), reason: '抽出来的帧应该是竖的');

    // 守卫：检测区域必须**只覆盖标记**。没有这条，判据一松就会把整张图框进去，
    // 然后「红块消失」轻松通过，实际什么都没验（已经栽过一次）。
    final boxW = red![2] - red[0];
    final boxH = red[3] - red[1];
    final areaRatio = (boxW * boxH) / (inImg.width * inImg.height);
    debugPrint(
      'VTEST_ROT 红块框=${boxW}x$boxH 占画面 ${(areaRatio * 100).toStringAsFixed(1)}%',
    );
    expect(
      areaRatio,
      lessThan(0.06),
      reason:
          '红块包围盒占了画面 ${(areaRatio * 100).toStringAsFixed(1)}% —— '
          '要么素材里还有别的红色物体，要么红色判据太松，这个测试会变成假通过',
    );
    // 标记是 200x100 的横条，转过 90° 之后应该是 1:2 的竖条
    expect(
      boxH / boxW,
      inInclusiveRange(1.3, 2.8),
      reason: '红块长宽比 ${(boxH / boxW).toStringAsFixed(2)} 与标记（转过 90° 应是 1:2）不符',
    );

    // 3) 归一化 + 少量外扩，盖住抗锯齿边缘
    final pad = 3.0 / inImg.width;
    final selection = Rect.fromLTRB(
      red[0] / inImg.width - pad,
      red[1] / inImg.height - pad,
      red[2] / inImg.width + pad,
      red[3] / inImg.height + pad,
    );
    debugPrint(
      'VTEST_ROT selection=(${selection.left.toStringAsFixed(4)}, '
      '${selection.top.toStringAsFixed(4)}, '
      '${selection.right.toStringAsFixed(4)}, '
      '${selection.bottom.toStringAsFixed(4)})',
    );

    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      taskId: 'vtest-rot90',
    );
    debugPrint(
      'VTEST_ROT repair rot=${result.rotation} frames=${result.frames} '
      'size=${result.width}x${result.height} '
      '${result.elapsed.inMilliseconds}ms',
    );

    expect(out.existsSync(), isTrue, reason: '产物必须落盘');
    expect(
      result.rotation,
      meta.rotation,
      reason: '转码用的旋转 ${result.rotation} 与探测到的 ${meta.rotation} 不一致',
    );
    expect(
      result.width,
      meta.width,
      reason: '编码宽高应该保持 ${meta.width}，实际 ${result.width}',
    );
    expect(result.height, meta.height);

    // 4) 产物必须仍然带 90° 标记（setOrientationHint 生效），否则播放器会横着放
    final outMeta = await probe.probe(out.path);
    debugPrint(
      'VTEST_ROT_OUT probe 编码=${outMeta.width}x${outMeta.height} '
      'rot=${outMeta.rotation} 显示=${outMeta.displayWidth}x${outMeta.displayHeight} '
      'dur=${outMeta.duration.inMilliseconds}ms',
    );
    expect(
      outMeta.rotation,
      meta.rotation,
      reason:
          '产物旋转从 ${meta.rotation} 变成 ${outMeta.rotation} —— '
          'muxer.setOrientationHint 没生效或没调用',
    );
    expect(
      (outMeta.duration.inMilliseconds - meta.duration.inMilliseconds).abs(),
      lessThan(120),
      reason: '时长变了：${meta.duration.inMilliseconds} → ${outMeta.duration.inMilliseconds}ms',
    );

    // 5) 红块必须几乎消失
    final afterFrame = await probe.extractFrame(
      path: out.path,
      outputPath: '${dir.path}/rot_out.png',
      position: Duration.zero,
    );
    final afterImg = img.decodeImage(await File(afterFrame.path).readAsBytes());
    if (afterImg == null) throw StateError('输出帧解码失败');

    final redBefore = _countRed(inImg);
    final redAfter = _countRed(afterImg);
    debugPrint(
      'VTEST_ROT_RED 修前=$redBefore 修后=$redAfter '
      '残留=${(redAfter / redBefore * 100).toStringAsFixed(1)}%',
    );

    expect(
      redAfter,
      lessThan(redBefore * 0.1),
      reason:
          '红块还剩 ${(redAfter / redBefore * 100).toStringAsFixed(1)}% —— '
          'Mask 没有落在红块上，说明 mapMaskToFrame 的 90° 映射方向错了',
    );
  });
}

Future<File> _materialize(Directory dir, String asset, String name) async {
  final data = await rootBundle.load(asset);
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file;
}

/// 纯红像素的包围盒 `[x0, y0, x1, y1]`（像素坐标，右/下为开区间）。
List<int>? _redBox(img.Image im) {
  final bytes = im.getBytes(order: img.ChannelOrder.rgb);
  var x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final i = (y * im.width + x) * 3;
      if (_isRed(bytes[i], bytes[i + 1], bytes[i + 2])) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return null;
  return [x0, y0, x1 + 1, y1 + 1];
}

/// 是否「真正的红」。
///
/// 早先写的是 `r > 150 && g < 90 && b < 90` —— 在这张暖色调的照片上，
/// 暗橙木色 `(156, 85, 16)` 也满足条件，于是「红块包围盒」扩到了画面的 77%×73%，
/// Mask 把大半张图都修了，而断言「修后红像素为 0」照样通过 —— **假通过**。
/// 改成「红必须显著压过绿蓝」，这种暖色就被排除了。
bool _isRed(int r, int g, int b) {
  final other = g > b ? g : b;
  return r > 160 && r - other > 110;
}

int _countRed(img.Image im) {
  final bytes = im.getBytes(order: img.ChannelOrder.rgb);
  var n = 0;
  for (var i = 0; i < bytes.length; i += 3) {
    if (_isRed(bytes[i], bytes[i + 1], bytes[i + 2])) n++;
  }
  return n;
}
