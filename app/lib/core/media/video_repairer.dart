import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../processing/processing_error.dart';
import 'media_channel.dart';

part 'video_repairer.g.dart';

/// 视频修复的两趟。
///
/// 开了「跟随画面」时，原生侧会跑两遍解码：第一趟只算每帧相对首帧的变换
/// （不解码成可看画面、不修、不编），第二趟按第一趟的轨迹逐帧修复并编码。
/// 所以一条任务会先后报两个阶段的进度，**各自从 0 走到 100** ——
/// 它们不是同一条进度条的两段，不能合成一个百分比（合并就要编权重，那是假进度）。
///
/// 关掉跟随时只有 [repair] 一趟。
enum VideoRepairPhase {
  /// 还没有收到任何进度
  idle,

  /// 第一趟：分析镜头运动（只解一次码，算全片轨迹）
  motion,

  /// 第二趟：逐帧修复并编码
  repair,
}

/// 一次视频修复的产出。
///
/// [frames] 与 [skippedFrames] 要一起看：`skippedFrames` 是「解码器给了空 buffer」的次数，
/// 少量属于正常现象，接近 [frames] 说明这条解码通路在这个机型上不可用 —— 别把它当成成功。
@immutable
class VideoRepairResult {
  const VideoRepairResult({
    required this.outputPath,
    required this.width,
    required this.height,
    required this.rotation,
    required this.frames,
    required this.skippedFrames,
    required this.videoBytes,
    required this.audioBytes,
    required this.hasAudio,
    required this.maskPixels,
    required this.sizeBytes,
    required this.elapsed,
    this.motionTracked = 0,
    this.motionFailed = 0,
    this.motionShiftPx = 0,
    this.motionScale = 1,
    this.motionRotationDeg = 0,
    this.motionShiftX = 0,
    this.motionShiftY = 0,
    this.directShiftPx = 0,
    this.directScale = 1,
    this.driftPx = 0,
    this.keyframeSwitches = 0,
    this.motionInliers = 0,
    this.maskRatio = 0,
  });

  factory VideoRepairResult.fromChannelMap(Map<String, Object?> map) {
    return VideoRepairResult(
      outputPath: map['outputPath'] as String? ?? '',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      rotation: (map['rotation'] as num?)?.toInt() ?? 0,
      frames: (map['frames'] as num?)?.toInt() ?? 0,
      skippedFrames: (map['skippedFrames'] as num?)?.toInt() ?? 0,
      videoBytes: (map['videoBytes'] as num?)?.toInt() ?? 0,
      audioBytes: (map['audioBytes'] as num?)?.toInt() ?? 0,
      hasAudio: map['hasAudio'] as bool? ?? false,
      maskPixels: (map['maskPixels'] as num?)?.toInt() ?? 0,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      elapsed: Duration(milliseconds: (map['elapsedMs'] as num?)?.toInt() ?? 0),
      motionTracked: (map['motionTracked'] as num?)?.toInt() ?? 0,
      motionFailed: (map['motionFailed'] as num?)?.toInt() ?? 0,
      motionShiftPx: (map['motionShiftPx'] as num?)?.toDouble() ?? 0,
      motionScale: (map['motionScale'] as num?)?.toDouble() ?? 1,
      motionRotationDeg: (map['motionRotationDeg'] as num?)?.toDouble() ?? 0,
      motionShiftX: (map['motionShiftX'] as num?)?.toDouble() ?? 0,
      motionShiftY: (map['motionShiftY'] as num?)?.toDouble() ?? 0,
      directShiftPx: (map['directShiftPx'] as num?)?.toDouble() ?? 0,
      directScale: (map['directScale'] as num?)?.toDouble() ?? 1,
      driftPx: (map['driftPx'] as num?)?.toDouble() ?? 0,
      keyframeSwitches: (map['keyframeSwitches'] as num?)?.toInt() ?? 0,
      motionInliers: (map['motionInliers'] as num?)?.toInt() ?? 0,
      maskRatio: (map['maskRatio'] as num?)?.toDouble() ?? 0,
    );
  }

  final String outputPath;
  final int width;
  final int height;
  final int rotation;
  final int frames;
  final int skippedFrames;
  final int videoBytes;
  final int audioBytes;
  final bool hasAudio;
  final int maskPixels;
  final int sizeBytes;
  final Duration elapsed;

  /// 选区占画面的比例（0~1）。
  ///
  /// 为什么单独带出来：TELEA 是扩散型填充，洞大了没有纹理可用，结果必然是一片平滑色斑
  /// （实测 353×365 的洞占 960×540 画面 24.9%，填出来是一个 X 形灰斑）。
  /// 这不是参数能修的，只能让用户知道「框太大」——UI 用 [maskRatioTooBig] 判断要不要提示。
  final double maskRatio;

  /// 选区是否大到「填出来必然是一块平色」。阈值 12%，与 Kotlin 侧 `BIG_MASK_RATIO` 一致。
  bool get maskRatioTooBig => maskRatio > 0.12;

  /// 镜头运动跟踪成功 / 失败的帧数（`trackMotion=false` 时都是 0）。
  final int motionTracked;
  final int motionFailed;

  /// 首帧到末帧的累计平移（像素）与累计缩放（1.0 = 没缩放）。
  final double motionShiftPx;
  final double motionScale;

  /// 累计旋转（度）。符号与自检里 `Motion.rotationDeg` 同一公式（`atan2(m[3], m[0])`）。
  final double motionRotationDeg;

  /// 累计平移的分量。方向必须单独断言 —— 模长相同、方向相反是两种完全不同的结果。
  final double motionShiftX;
  final double motionShiftY;

  /// 首帧到末帧**直接**估一次得到的平移（不累积），作为累计值的对照。
  final double directShiftPx;
  final double directScale;

  /// 累计值与直接值之差。接近 0 说明逐帧累加没有漂移；几十像素说明光流在飘。
  final double driftPx;

  /// 跟踪途中换了几次关键帧。
  ///
  /// 之前是「对上一帧估」，150 帧就是 150 次链式累积；改成关键帧之后，
  /// 误差只在换关键帧的那几次里传递。这个数越接近 `帧数 / 24` 越理想，
  /// 明显偏大说明特征点掉得快、基准帧一直在重设（表现为 Mask 跟不上）。
  final int keyframeSwitches;

  /// 最后一次估计的内点数（判跟踪质量：干净素材 190+，纹理弱时几十）。
  final int motionInliers;

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
    return '${(sizeBytes / 1024).round()} KB';
  }

  /// 每秒处理多少帧。低于 5 就说明这条路在真机上太慢，得考虑降分辨率或换算法。
  double get framesPerSecond {
    final ms = elapsed.inMilliseconds;
    if (ms <= 0) return 0;
    return frames / (ms / 1000);
  }
}

/// 视频修复通道。
///
/// 唯一的输入是**归一化选区**（0..1，相对用户看到的画面）—— 不传像素、不传 Mask 图。
/// 原因：视频帧的真实尺寸要等解码器吐出第一帧才知道（可能带编码对齐 padding），
/// 而旋转是写在容器里的元数据，帧本身是「编码朝向」的。
/// 归一化坐标是唯一能在三个坐标系（手势 / 显示 / 帧）之间无损转换的表达。
class VideoRepairer {
  const VideoRepairer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kMediaChannelName);

  final MethodChannel _channel;

  Future<VideoRepairResult> repair({
    required String inputPath,
    required String outputPath,
    required Rect selection,
    // 与图片路径对齐（图片是 6/8）。原来这里 4：同一个洞上半径越小填得越糊，
    // 实测 inpaint 只占单帧几毫秒，这点开销换观感划算。
    int radius = 6,
    bool trackMotion = false,
    /// 用户涂抹生成的遮罩 PNG（**显示方向**、与封面帧同尺寸）。
    ///
    /// 传了它原生就按这张图修（形状不规则时只能这样）；不传仍按 [selection]
    /// 画矩形，行为与以前完全一致。旋转视频的「显示→编码」朝向转换在原生做，
    /// 因为只有那边知道解码器的真实帧尺寸。
    String? maskPath,
    String? taskId,
    void Function(VideoRepairPhase phase, int done, int total)? onProgress,
  }) async {
    final id = taskId ?? 'video-${DateTime.now().microsecondsSinceEpoch}';

    // Kotlin 侧用 invokeMethod 反向推进度；没设 handler 时框架会静默忽略，不会报错。
    final listenProgress = onProgress != null;
    if (listenProgress) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'onVideoProgress') return null;
        final args = call.arguments;
        if (args is! Map || args['taskId'] != id) return null;
        onProgress(
          args['phase'] == 'motion'
              ? VideoRepairPhase.motion
              : VideoRepairPhase.repair,
          (args['done'] as num?)?.toInt() ?? 0,
          (args['total'] as num?)?.toInt() ?? 0,
        );
        return null;
      });
    }

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('repairVideo', {
        'inputPath': inputPath,
        'outputPath': outputPath,
        'left': selection.left,
        'top': selection.top,
        'right': selection.right,
        'bottom': selection.bottom,
        'radius': radius,
        'trackMotion': trackMotion,
        'maskPath': maskPath,
        'taskId': id,
      });
      if (raw == null) {
        throw const ProcessingException(
          ProcessingErrorCode.nativeFailure,
          detail: '视频修复没有返回数据',
        );
      }
      return VideoRepairResult.fromChannelMap(raw);
    } on PlatformException catch (error) {
      throw ProcessingException(
        ProcessingErrorCode.fromCode(error.code),
        detail: error.message,
      );
    } on MissingPluginException {
      throw const ProcessingException(
        ProcessingErrorCode.nativeFailure,
        detail: '平台通道未注册',
      );
    } finally {
      if (listenProgress) _channel.setMethodCallHandler(null);
    }
  }

  /// 运动估计器的**已知真值自检**（不参与产品流程，只给测试用）。
  ///
  /// 用一张真实照片造出已知的平移 / 旋转 / 缩放，再让估计器还原，返回每例的误差。
  /// 这是在没有「带真水印的视频」时唯一能验证算法正确性的办法。
  Future<List<MotionSelfTestCase>> motionSelfTest(String imagePath) async {
    final raw = await _channel.invokeListMethod<Object?>('motionSelfTest', {
      'imagePath': imagePath,
    });
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((m) => MotionSelfTestCase.fromMap(m.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// 取消一个正在跑的任务。Kotlin 侧按帧检查标记位，最迟下一帧生效。
  Future<void> cancel(String taskId) async {
    await _channel.invokeMethod<void>('cancel', {'taskId': taskId});
  }
}

/// 运动估计自检的一例结果。真值是测试自己造的，所以 [posErrPx] 可以直接断言。
@immutable
class MotionSelfTestCase {
  const MotionSelfTestCase({
    required this.name,
    required this.posErrPx,
    required this.angleErrDeg,
    required this.scaleErr,
    required this.tracked,
    required this.inliers,
    required this.residualPx,
    required this.ok,
  });

  factory MotionSelfTestCase.fromMap(Map<String, Object?> map) {
    return MotionSelfTestCase(
      name: map['name'] as String? ?? '?',
      posErrPx: (map['posErrPx'] as num?)?.toDouble() ?? double.infinity,
      angleErrDeg: (map['angleErrDeg'] as num?)?.toDouble() ?? double.infinity,
      scaleErr: (map['scaleErr'] as num?)?.toDouble() ?? double.infinity,
      tracked: (map['tracked'] as num?)?.toInt() ?? 0,
      inliers: (map['inliers'] as num?)?.toInt() ?? 0,
      residualPx: (map['residualPx'] as num?)?.toDouble() ?? 0,
      ok: map['ok'] as bool? ?? false,
    );
  }

  final String name;
  final double posErrPx;
  final double angleErrDeg;
  final double scaleErr;
  final int tracked;
  final int inliers;
  final double residualPx;
  final bool ok;

  @override
  String toString() =>
      '$name: ok=$ok 角误差=${angleErrDeg.toStringAsFixed(2)}° '
      '缩放误差=${scaleErr.toStringAsFixed(4)} 位置误差=${posErrPx.toStringAsFixed(2)}px '
      '(tracked=$tracked inliers=$inliers residual=${residualPx.toStringAsFixed(2)}px)';
}

@Riverpod(keepAlive: true)
VideoRepairer videoRepairer(Ref ref) => const VideoRepairer();
