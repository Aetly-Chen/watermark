import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/video_probe.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';

/// 镜头运动（全局运动估计）的真机验证。
///
/// ## 为什么需要「人造真值」
///
/// 手上的真实素材（`sample.mp4` 花瓣）里没有真水印，只有一块被框起来的花瓣，
/// 没有语义基准可比。拿它验「跟得准不准」只能靠肉眼，那不是证据。
///
/// 所以素材是**造出来的**，位移由脚本按整数像素逐帧指定：
///
/// | 素材 | 造法 | 真值 |
/// |---|---|---|
/// | `motion_still.mp4` | 150 帧同一块裁剪 | 位移 (0, 0) |
/// | `motion_pan.mp4` | 第 n 帧裁剪左上角移到 (2n, n) | 内容左上移 (298, 149) |
/// | `motion_zoom.mp4` | 第 n 帧把源缩放到 (960+144n/149) 再居中裁 960×540 | 绕中心放大 1.15 倍 → `scale=1.15`、`t=(-72,-40.5)` |
///
/// 真值不是「我以为」，是用 PSNR 反查过的：在 `motion_pan.mp4` 上，
/// 按 (298,149) 对齐 frame0 与 frame149 得 32.9 dB，故意错开 10px 只有 14.9 dB。
/// 变焦那条是搜出来的：把 frame149 缩回 1/s 贴回原尺寸，中心区 MAE 在 s=1.15 处
/// 取到 4.86（1.13→15.08、1.17→13.71），峰非常尖。
///
/// ## 「绕中心缩放」的平移分量为什么不是 0
///
/// 相似变换写成 `p' = s·p + t`。若缩放中心是画面中心 c，则 `p' = c + s(p-c)`，
/// 即 `t = c(1-s)`。所以 1.15 倍居中放大的平移是 `(480·(-0.15), 270·(-0.15)) = (-72, -40.5)`。
/// 断言这个比断言「≈0」有力得多 —— 它同时验了「缩放对」和「缩放中心对」。
///
/// ## 四组断言各守一个失败面
///
/// 1. **算法本身**：自检用已知的平移/旋转/缩放 warp 真实照片，比对还原误差；
/// 2. **静止不漂**：真值 0 的素材上累计位移必须仍是 0 —— 这条专抓「光流亚像素偏置累积」；
/// 3. **方向与幅度**：真值 (298,149) 的素材上必须解出 (-298,-149)，
///    方向和模长都要对（只断模长会把「反了」当成通过）；
/// 4. **Mask 真的跟着走了**：抽第 120 帧，检查「被修复的区域」在**移动后**的位置上，
///    而不是留在原地 —— 这是唯一能证明「修的是水印而不是一块固定的屏幕区域」的断言；
/// 5. **缩放与缩放中心**：已知 1.15 倍居中变焦上，`scale` 对且平移分量等于 `c(1-s)`。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const repairer = VideoRepairer();
  const probe = VideoProbe();

  /// 用户框选：画面归一化坐标。故意挑一块纹理丰富的地方（cafe 的吧台/灯），
  /// 纹理太弱的话光流本来就跟不住，会把「算法问题」和「素材问题」混在一起。
  const selection = Rect.fromLTRB(0.40, 0.35, 0.58, 0.52);

  testWidgets('运动估计器：已知真值能还原', (tester) async {
    final dir = await getTemporaryDirectory();
    final image = await _materializeAsset(dir, 'assets/samples/cafe.jpg', 'motion_self.jpg');

    final cases = await repairer.motionSelfTest(image.path);
    expect(cases, isNotEmpty, reason: '自检没返回任何结果');
    for (final c in cases) {
      debugPrint('VTEST_MOTION $c');
    }

    for (final c in cases) {
      expect(c.ok, isTrue, reason: '「${c.name}」被判为估计失败');
      expect(
        c.posErrPx,
        lessThan(3.0),
        reason: '「${c.name}」四角最大位置误差 ${c.posErrPx.toStringAsFixed(2)}px，超过 3px',
      );
      expect(
        c.angleErrDeg,
        lessThan(1.0),
        reason: '「${c.name}」角度误差 ${c.angleErrDeg.toStringAsFixed(2)}°，超过 1°',
      );
      expect(
        c.scaleErr,
        lessThan(0.02),
        reason: '「${c.name}」缩放误差 ${c.scaleErr.toStringAsFixed(4)}，超过 2%',
      );
      // 内点太少的「成功」是靠一两个点凑出来的，位置误差可能很好看但不可信
      expect(c.inliers, greaterThanOrEqualTo(12), reason: '「${c.name}」内点只有 ${c.inliers} 个');
    }
  });

  testWidgets('静止素材：累计位移必须仍是 0（防光流漂移）', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeAsset(dir, 'assets/samples/motion_still.mp4', 'still.mp4');
    final out = File('${dir.path}/still_out.mp4');
    if (out.existsSync()) out.deleteSync();

    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      trackMotion: true,
      taskId: 'vtest-still',
    );

    debugPrint(
      'VTEST_STILL frames=${result.frames} tracked=${result.motionTracked} '
      'failed=${result.motionFailed} '
      'shift=(${result.motionShiftX.toStringAsFixed(2)}, '
      '${result.motionShiftY.toStringAsFixed(2)}) '
      'direct=${result.directShiftPx.toStringAsFixed(2)}px '
      'drift=${result.driftPx.toStringAsFixed(2)}px '
      'keyframes=${result.keyframeSwitches} inliers=${result.motionInliers} '
      '${result.elapsed.inMilliseconds}ms',
    );

    expect(out.existsSync(), isTrue);
    expect(
      result.motionTracked + result.motionFailed,
      result.frames - 1,
      reason: '估计次数应等于帧数减一（首帧没有上一帧）',
    );

    // 素材是真静止的（PSNR 56.9 dB，frame0 与 frame149 几乎逐像素相同），
    // 所以任何非零位移都只能来自算法，不能赖素材。
    expect(
      result.motionShiftX.abs(),
      lessThan(1.5),
      reason:
          '静止素材上累计 X 位移 ${result.motionShiftX.toStringAsFixed(2)}px —— '
          '逐帧累加把光流的亚像素偏置乘上 149 帧了',
    );
    expect(
      result.motionShiftY.abs(),
      lessThan(1.5),
      reason: '静止素材上累计 Y 位移 ${result.motionShiftY.toStringAsFixed(2)}px',
    );
    expect(
      result.motionScale,
      inInclusiveRange(0.995, 1.005),
      reason: '静止素材上缩放应为 1，实际 ${result.motionScale.toStringAsFixed(4)}',
    );
  });

  testWidgets('已知平移素材：方向与幅度都要对', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeAsset(dir, 'assets/samples/motion_pan.mp4', 'pan.mp4');
    final out = File('${dir.path}/pan_out.mp4');
    if (out.existsSync()) out.deleteSync();

    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      trackMotion: true,
      taskId: 'vtest-pan',
    );

    debugPrint(
      'VTEST_PAN frames=${result.frames} tracked=${result.motionTracked} '
      'failed=${result.motionFailed} '
      'shift=(${result.motionShiftX.toStringAsFixed(2)}, '
      '${result.motionShiftY.toStringAsFixed(2)}) '
      'scale=${result.motionScale.toStringAsFixed(4)} '
      'direct=(${result.directShiftPx.toStringAsFixed(2)}px) '
      'drift=${result.driftPx.toStringAsFixed(2)}px '
      'keyframes=${result.keyframeSwitches} inliers=${result.motionInliers} '
      '${result.elapsed.inMilliseconds}ms ${result.framesPerSecond.toStringAsFixed(1)}fps',
    );

    // 真值：每帧 (2, 1)，149 帧后内容左上移 (298, 149) → 变换平移 = (-298, -149)
    const truthX = -298.0;
    const truthY = -149.0;

    expect(
      (result.motionShiftX - truthX).abs(),
      lessThan(4.0),
      reason:
          '累计 X 位移应是 ${truthX.toStringAsFixed(0)}px，'
          '实际 ${result.motionShiftX.toStringAsFixed(2)}px',
    );
    expect(
      (result.motionShiftY - truthY).abs(),
      lessThan(4.0),
      reason:
          '累计 Y 位移应是 ${truthY.toStringAsFixed(0)}px，'
          '实际 ${result.motionShiftY.toStringAsFixed(2)}px',
    );
    expect(
      result.motionScale,
      inInclusiveRange(0.98, 1.02),
      reason: '纯平移不该解出缩放，实际 ${result.motionScale.toStringAsFixed(4)}',
    );
    expect(
      result.motionFailed,
      lessThan(result.frames * 0.1),
      reason: '${result.motionFailed} 帧估计失败（超过 10%）',
    );
  });

  testWidgets('已知变焦素材：缩放倍数与缩放中心都要对', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeAsset(
      dir,
      'assets/samples/motion_zoom.mp4',
      'zoom.mp4',
    );
    final out = File('${dir.path}/zoom_out.mp4');
    if (out.existsSync()) out.deleteSync();

    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      trackMotion: true,
      taskId: 'vtest-zoom',
    );

    debugPrint(
      'VTEST_ZOOM frames=${result.frames} tracked=${result.motionTracked} '
      'failed=${result.motionFailed} '
      'shift=(${result.motionShiftX.toStringAsFixed(2)}, '
      '${result.motionShiftY.toStringAsFixed(2)}) '
      'scale=${result.motionScale.toStringAsFixed(4)} '
      'drift=${result.driftPx.toStringAsFixed(2)}px '
      'keyframes=${result.keyframeSwitches} inliers=${result.motionInliers} '
      '${result.elapsed.inMilliseconds}ms ${result.framesPerSecond.toStringAsFixed(1)}fps',
    );

    // 真值：960 → 1104 居中放大 1.15 倍。
    // 相似变换 p' = s·p + t，绕中心 c 缩放时 t = c(1-s)，
    // c = (960/2, 540/2) = (480, 270) → t = (-72, -40.5)。
    const truthScale = 1.15;
    const truthTx = -72.0;
    const truthTy = -40.5;

    expect(
      (result.motionScale - truthScale).abs(),
      lessThan(0.015),
      reason:
          '累计缩放应是 $truthScale，实际 ${result.motionScale.toStringAsFixed(4)} —— '
          '偏小说明缩放没跟住，偏大说明把光流的尺度偏差也累进来了',
    );
    expect(
      (result.motionShiftX - truthTx).abs(),
      lessThan(5.0),
      reason:
          '绕中心缩放的 X 平移应是 ${truthTx.toStringAsFixed(1)}px，'
          '实际 ${result.motionShiftX.toStringAsFixed(2)}px —— '
          '这条同时验了「缩放对」和「缩放中心对」，错一个都会偏',
    );
    expect(
      (result.motionShiftY - truthTy).abs(),
      lessThan(5.0),
      reason:
          '绕中心缩放的 Y 平移应是 ${truthTy.toStringAsFixed(1)}px，'
          '实际 ${result.motionShiftY.toStringAsFixed(2)}px',
    );
    expect(
      result.motionFailed,
      lessThan(result.frames * 0.1),
      reason: '${result.motionFailed} 帧估计失败（超过 10%）',
    );
  });

  testWidgets('手持抖动素材：旋转 + 平移复合', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeAsset(
      dir,
      'assets/samples/motion_shake.mp4',
      'shake.mp4',
    );
    final out = File('${dir.path}/shake_out.mp4');
    if (out.existsSync()) out.deleteSync();

    final result = await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      trackMotion: true,
      taskId: 'vtest-shake',
    );

    debugPrint(
      'VTEST_SHAKE frames=${result.frames} tracked=${result.motionTracked} '
      'failed=${result.motionFailed} '
      'angle=${result.motionRotationDeg.toStringAsFixed(3)}° '
      'scale=${result.motionScale.toStringAsFixed(4)} '
      'shift=(${result.motionShiftX.toStringAsFixed(2)}, '
      '${result.motionShiftY.toStringAsFixed(2)}) '
      'drift=${result.driftPx.toStringAsFixed(2)}px '
      'keyframes=${result.keyframeSwitches} inliers=${result.motionInliers} '
      '${result.elapsed.inMilliseconds}ms ${result.framesPerSecond.toStringAsFixed(1)}fps',
    );

    // 真值由 `D:/dev/vt/make_shake.py` 的 pose(149) 给出：
    //   θ = 0.02·149 + 0.5·sin(2π·149/40) = 2.4862°
    //   dx = 0.40·149 + 2.5·sin(2π·149/33) = 59.362
    //   dy = -0.25·149 + 1.8·cos(2π·149/27) = -39.038
    // 变换形式是 p' = R·p + t（绕左上角），所以 t 就是 (dx, dy)，没有补偿项。
    // 自检：把末帧按这个真值正变换回看首帧，中心区 MAE=8.37（两次插值的代价）。
    const truthAngle = 2.4862;
    const truthTx = 59.362;
    const truthTy = -39.038;

    expect(
      (result.motionRotationDeg - truthAngle).abs(),
      lessThan(0.4),
      reason:
          '累计旋转应是 ${truthAngle.toStringAsFixed(2)}°，'
          '实际 ${result.motionRotationDeg.toStringAsFixed(3)}° —— '
          '符号反了说明 atan2 的约定和自检不一致',
    );
    expect(
      (result.motionShiftX - truthTx).abs(),
      lessThan(6.0),
      reason:
          '累计 X 位移应是 ${truthTx.toStringAsFixed(1)}px，'
          '实际 ${result.motionShiftX.toStringAsFixed(2)}px',
    );
    expect(
      (result.motionShiftY - truthTy).abs(),
      lessThan(6.0),
      reason:
          '累计 Y 位移应是 ${truthTy.toStringAsFixed(1)}px，'
          '实际 ${result.motionShiftY.toStringAsFixed(2)}px',
    );
    expect(
      result.motionScale,
      inInclusiveRange(0.99, 1.01),
      reason: '抖动素材只有旋转和平移，不该解出缩放，实际 ${result.motionScale.toStringAsFixed(4)}',
    );
  });

  testWidgets('Mask 跟着内容走：第 135 帧被修的是移动后的位置', (tester) async {
    final dir = await getTemporaryDirectory();
    final video = await _materializeAsset(dir, 'assets/samples/motion_pan.mp4', 'pan_mask.mp4');
    final out = File('${dir.path}/pan_mask_out.mp4');
    if (out.existsSync()) out.deleteSync();

    await repairer.repair(
      inputPath: video.path,
      outputPath: out.path,
      selection: selection,
      trackMotion: true,
      taskId: 'vtest-mask',
    );

    // 抽帧走 `OPTION_CLOSEST_SYNC`，只会给**关键帧**。输入是我造的（每 15 帧一个关键帧），
    // 输出是 App 重编码的（MediaCodec 默认 1 秒一个，即每 30 帧）。
    // 两边都能精确命中的时间点只有 4000ms —— 也就是第 120 帧。
    // 挑 4500ms 会拿到输入的 135 帧、输出的 120 或 150 帧，两帧不同的画面比出来全是噪声（踩过）。
    const t = Duration(milliseconds: 4000);
    const frameIndex = 120;
    const shiftX = frameIndex * 2.0;
    const shiftY = frameIndex * 1.0;
    final before = await _frame(probe, video.path, '${dir.path}/f135_in.png', t);
    final after = await _frame(probe, out.path, '${dir.path}/f135_out.png', t);

    final movedBox = _shiftBox(selection, before.width, before.height, -shiftX, -shiftY);
    final origBox = _box(selection, before.width, before.height);

    final maeMoved = _maeIn(before, after, movedBox);
    final maeOrig = _maeIn(before, after, origBox);
    final maeOutside = _maeOutside(before, after, movedBox);
    // 全帧 MAE 是个「对齐体检」：抽帧没对齐时它会大得离谱（几十），
    // 对齐正常时只剩重编码噪声（个位数）。有它才能一眼分清「跟踪错了」和「比错帧了」。
    final maeAll = _maeIn(before, after, [0, 0, before.width, before.height]);

    debugPrint(
      'VTEST_MASKFRAME t=4000ms 移动后框=$movedBox 原框=$origBox '
      'mae(移动后框)=${maeMoved.toStringAsFixed(2)} '
      'mae(原框)=${maeOrig.toStringAsFixed(2)} '
      'mae(框外)=${maeOutside.toStringAsFixed(2)} '
      'mae(全帧)=${maeAll.toStringAsFixed(2)}',
    );

    // 1) 移动后的位置必须被修过 —— 这是「跟上了」的核心证据
    expect(
      maeMoved,
      greaterThan(10.0),
      reason:
          '第 135 帧「水印应该在的位置」(移动 $shiftX, $shiftY px 后) 几乎没变化 '
          '(mae=${maeMoved.toStringAsFixed(2)}) —— Mask 没跟过去',
    );
    // 2) 框外必须干净 —— 证明没有把整片区域糊掉
    expect(
      maeOutside,
      lessThan(8.0),
      reason:
          '移动后框以外的区域 mae=${maeOutside.toStringAsFixed(2)}，画面被改脏了。'
          '先看 mae(全帧)=${maeAll.toStringAsFixed(2)}：如果它也很大，'
          '那是抽帧没对齐（关键帧位置不同），不是跟踪的问题',
    );
    // 3) 原位置不该被修（否则就是「没跟随、修了一块固定的屏幕区域」）。
    //    mae(原框) 天然会比 mae(移动后框) 低，因为原框里根本没有 Mask 了；
    //    这条断言把「两个位置都修了」（Mask 变大了）也排除掉。
    expect(
      maeOrig,
      lessThan(maeMoved * 0.5),
      reason:
          '原框 mae=${maeOrig.toStringAsFixed(2)} 与移动后框 '
          'mae=${maeMoved.toStringAsFixed(2)} 相当 —— 说明 Mask 没有移动，'
          '而是把两个位置都修了或都没修',
    );
  });
}

Future<File> _materializeAsset(Directory dir, String asset, String name) async {
  final data = await rootBundle.load(asset);
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return file;
}

Future<img.Image> _frame(
  VideoProbe probe,
  String path,
  String outputPath,
  Duration position,
) async {
  final frame = await probe.extractFrame(
    path: path,
    outputPath: outputPath,
    position: position,
  );
  final decoded = img.decodeImage(await File(frame.path).readAsBytes());
  if (decoded == null) throw StateError('对比帧解码失败：${frame.path}');
  return decoded;
}

/// 归一化选区 → 像素矩形 `(x0, y0, x1, y1)`。
List<int> _box(Rect selection, int w, int h) => [
  (selection.left * w).round(),
  (selection.top * h).round(),
  (selection.right * w).round(),
  (selection.bottom * h).round(),
];

/// 归一化选区 → 平移后的像素矩形。`dx/dy` 是内容位移（负值 = 往左上走）。
List<int> _shiftBox(Rect selection, int w, int h, double dx, double dy) {
  final b = _box(selection, w, h);
  return [
    b[0] + dx.round(),
    b[1] + dy.round(),
    b[2] + dx.round(),
    b[3] + dy.round(),
  ];
}

double _maeIn(img.Image a, img.Image b, List<int> box) =>
    _mae(a, b, box, inside: true);

double _maeOutside(img.Image a, img.Image b, List<int> box) =>
    _mae(a, b, box, inside: false);

double _mae(img.Image a, img.Image b, List<int> box, {required bool inside}) {
  final w = a.width;
  final h = a.height;
  if (b.width != w || b.height != h) return double.infinity;
  final pa = a.getBytes(order: img.ChannelOrder.rgb);
  final pb = b.getBytes(order: img.ChannelOrder.rgb);
  final x0 = box[0].clamp(0, w);
  final y0 = box[1].clamp(0, h);
  final x1 = box[2].clamp(0, w);
  final y1 = box[3].clamp(0, h);

  var sum = 0.0;
  var count = 0;
  for (var y = 0; y < h; y++) {
    final inRow = y >= y0 && y < y1;
    for (var x = 0; x < w; x++) {
      final inBox = inRow && x >= x0 && x < x1;
      if (inBox != inside) continue;
      final i = (y * w + x) * 3;
      final dr = (pa[i] - pb[i]).abs();
      final dg = (pa[i + 1] - pb[i + 1]).abs();
      final db = (pa[i + 2] - pb[i + 2]).abs();
      sum += dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}
