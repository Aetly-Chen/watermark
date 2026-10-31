import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/video_probe.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';

/// 真机验证视频修复管线：解码 → 逐帧修复 → 编码 → 封装。
///
/// 这条管线最怕的不是「跑不起来」，而是**静默跑错**：颜色偏了、PTS 错位、音轨丢了，
/// 画面上看起来都可能像「修得不太准」。所以断言分三组，每组对应一个独立的失败面：
///
/// 1. **容器层**：分辨率、时长、音轨 —— 错了说明封装或 PTS 有问题；
/// 2. **内容层**：框内必须变、框外必须几乎不变 —— 错了说明 YUV 转换或坐标映射有问题；
/// 3. **性能层**：只打印不占失败条件 —— 它取决于机型，不是正确性问题。
///
/// 为什么取 `position = 0` 对比：`getFrameAtTime` 用的是 OPTION_CLOSEST_SYNC（最近关键帧）。
/// 源文件和我们产出的 GOP 结构不同，取 1 秒处可能一个落在关键帧、一个落在前一个关键帧，
/// 比的是两张不同画面的帧，MAE 会爆掉但跟管线毫无关系。第 0 帧在两边都是关键帧，才可比。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例视频：修完仍是可播放的 MP4，框外像素不动', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeSample(dir);
    const probe = VideoProbe();
    const repairer = VideoRepairer();

    final inputMeta = await probe.probe(video.path);
    debugPrint(
      'VRTEST_IN ${inputMeta.width}x${inputMeta.height} rot=${inputMeta.rotation} '
      'dur=${inputMeta.duration.inMilliseconds}ms audio=${inputMeta.hasAudio} '
      '${inputMeta.sizeBytes}B',
    );

    // 选区故意放在画面中间偏左：那里有花瓣和背景的分界，修完必然和原来不同。
    // 挑一块纯色区会得到「几乎没变」，看起来像失败，其实是对的。
    const selection = Rect.fromLTRB(0.40, 0.35, 0.58, 0.52);
    final outputPath = '${dir.path}/fixed_vrtest.mp4';
    final outFile = File(outputPath);
    if (outFile.existsSync()) outFile.deleteSync();

    final progressLog = <int>[];
    final phases = <VideoRepairPhase>{};
    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: outputPath,
      selection: selection,
      radius: 4,
      taskId: 'vrtest',
      onProgress: (phase, done, total) {
        phases.add(phase);
        if (progressLog.length < 3) progressLog.add(done);
      },
    );

    debugPrint(
      'VRTEST_OUT ${result.width}x${result.height} rot=${result.rotation} '
      'frames=${result.frames} skipped=${result.skippedFrames} '
      'video=${result.videoBytes}B audio=${result.audioBytes}B hasAudio=${result.hasAudio} '
      'mask=${result.maskPixels}px ${result.sizeBytes}B ${result.elapsed.inMilliseconds}ms '
      '${result.framesPerSecond.toStringAsFixed(1)}fps progress=$progressLog',
    );

    // 这个用例没开 trackMotion，所以只有一趟 —— 不该冒出 motion 阶段
    expect(phases, contains(VideoRepairPhase.repair));
    expect(
      phases,
      isNot(contains(VideoRepairPhase.motion)),
      reason: '静止水印不该白跑一趟「分析镜头运动」',
    );
    // ---- 第一组：容器层 ----
    expect(outFile.existsSync(), isTrue, reason: '产物必须落盘');
    expect(result.sizeBytes, greaterThan(10000), reason: '产物不该是空文件');
    expect(
      result.sizeBytes,
      greaterThan(result.videoBytes + result.audioBytes),
      reason:
          '文件 ${result.sizeBytes}B 比「视频 ${result.videoBytes}B + 音频 ${result.audioBytes}B」'
          '还小 —— 说明体积是在 muxer flush 之前量的（这个断言就是为了拦住它复发）',
    );
    expect(result.frames, greaterThan(10), reason: '至少要有十几帧才算跑过管线');
    expect(
      result.skippedFrames,
      lessThan(result.frames ~/ 10),
      reason: '跳过帧超过 10% 说明这条解码通路在这个机型上不可靠',
    );
    expect(result.width, inputMeta.width, reason: '编码尺寸应保持源尺寸');
    expect(result.height, inputMeta.height);

    // Mask 像素数必须对得上「归一化选区 × 帧尺寸」，差太多就是坐标映射错了
    final expectedMaskPixels =
        (selection.width * result.width) * (selection.height * result.height);
    expect(
      (result.maskPixels - expectedMaskPixels).abs() / expectedMaskPixels,
      lessThan(0.05),
      reason:
          'mask=${result.maskPixels}px 与预期 ${expectedMaskPixels.round()}px 差太多，'
          '说明归一化坐标 → 帧坐标的换算错了',
    );

    final outputMeta = await probe.probe(outputPath);
    debugPrint(
      'VRTEST_META_OUT ${outputMeta.width}x${outputMeta.height} '
      'dur=${outputMeta.duration.inMilliseconds}ms audio=${outputMeta.hasAudio}',
    );
    expect(outputMeta.width, inputMeta.width, reason: '容器里记的分辨率要一致');
    expect(outputMeta.height, inputMeta.height);
    expect(outputMeta.hasAudio, inputMeta.hasAudio, reason: '音轨必须原样保留');
    expect(
      (outputMeta.duration.inMilliseconds - inputMeta.duration.inMilliseconds).abs(),
      lessThan(120),
      reason:
          '时长差 ${outputMeta.duration.inMilliseconds - inputMeta.duration.inMilliseconds}ms，'
          '超过 120ms 说明 PTS 没原样带过去',
    );

    // ---- 第二组：内容层 ----
    final before = await _extractFirstFrame(dir, probe, inputMeta.path, 'before');
    final after = await _extractFirstFrame(dir, probe, outputPath, 'after');
    expect(after.width, before.width, reason: '对比帧尺寸必须一致，否则没法逐像素比');
    expect(after.height, before.height);

    final x0 = (selection.left * before.width).round();
    final y0 = (selection.top * before.height).round();
    final x1 = (selection.right * before.width).round();
    final y1 = (selection.bottom * before.height).round();

    final metrics = _compare(before, after, x0, y0, x1, y1);
    debugPrint(
      'VRTEST_PIXEL inside_changed=${(metrics.insideChanged * 100).toStringAsFixed(1)}% '
      'outside_mae=${metrics.outsideMae.toStringAsFixed(2)} '
      'global_mae=${metrics.globalMae.toStringAsFixed(2)}',
    );

    expect(
      metrics.insideChanged,
      greaterThan(0.6),
      reason:
          '框内只有 ${(metrics.insideChanged * 100).round()}% 的像素变了，修复没落到选区里',
    );
    expect(
      metrics.outsideMae,
      lessThan(6.0),
      reason:
          '框外 MAE=${metrics.outsideMae.toStringAsFixed(2)}，超过 6 说明整帧颜色被改了 —— '
          'YUV 转换或编码参数有问题（不是「修得不准」，是整个画面脏了）',
    );

    // ---- 第三组：性能（只报告，不判定） ----
    debugPrint(
      'VRTEST_PERF ${result.elapsed.inMilliseconds}ms / ${result.frames} 帧 = '
      '${result.framesPerSecond.toStringAsFixed(1)} fps',
    );
  });
}

Future<File> _materializeSample(Directory dir) async {
  final data = await rootBundle.load('assets/samples/sample.mp4');
  final video = File('${dir.path}/sample_vrtest.mp4');
  await video.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return video;
}

Future<img.Image> _extractFirstFrame(
  Directory dir,
  VideoProbe probe,
  String videoPath,
  String tag,
) async {
  final frame = await probe.extractFrame(
    path: videoPath,
    outputPath: '${dir.path}/frame_$tag.png',
    position: Duration.zero,
  );
  final bytes = await File(frame.path).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('对比帧解码失败：${frame.path}');
  return decoded;
}

/// 框内「肉眼可见变化」的像素占比 + 框外的平均绝对误差。
///
/// 一趟扫完三组数字，而且走 `getBytes` 的裸字节缓冲 —— 用 `getPixel()` 逐点取会
/// 给每个像素 new 一个对象，518k 像素 × 3 趟在真机上要几十秒，纯属浪费。
///
/// 「变化」阈值 12 是为了滤掉 H.264 重编码带来的噪声：
/// 同一帧编码两次也会有 1~3 的差，那不是我们要找的「修复」。
_CompareMetrics _compare(
  img.Image a,
  img.Image b,
  int x0,
  int y0,
  int x1,
  int y1,
) {
  final w = a.width;
  final h = a.height;
  final pa = a.getBytes(order: img.ChannelOrder.rgb);
  final pb = b.getBytes(order: img.ChannelOrder.rgb);

  var insideChanged = 0;
  var insideTotal = 0;
  var outsideSum = 0.0;
  var outsideCount = 0;
  var globalSum = 0.0;
  var globalCount = 0;

  for (var y = 0; y < h; y++) {
    final inRow = y >= y0 && y < y1;
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      final dr = (pa[i] - pb[i]).abs();
      final dg = (pa[i + 1] - pb[i + 1]).abs();
      final db = (pa[i + 2] - pb[i + 2]).abs();
      // 单像素取最大通道差：单通道差会把「只有色度偏了」也算成没变
      final diff = dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);

      globalSum += diff;
      globalCount++;

      if (inRow && x >= x0 && x < x1) {
        insideTotal++;
        if (diff >= 12) insideChanged++;
      } else {
        outsideSum += diff;
        outsideCount++;
      }
    }
  }

  return _CompareMetrics(
    insideChanged: insideTotal == 0 ? 0 : insideChanged / insideTotal,
    outsideMae: outsideCount == 0 ? 0 : outsideSum / outsideCount,
    globalMae: globalCount == 0 ? 0 : globalSum / globalCount,
  );
}

class _CompareMetrics {
  const _CompareMetrics({
    required this.insideChanged,
    required this.outsideMae,
    required this.globalMae,
  });

  final double insideChanged;
  final double outsideMae;
  final double globalMae;
}
