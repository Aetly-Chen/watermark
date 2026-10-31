import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 帧耗时探针 —— 只在 `--dart-define=WM_FRAME_PROBE=true` 时生效。
///
/// 为什么需要它：`adb shell dumpsys gfxinfo` 与 `dumpsys SurfaceFlinger --latency`
/// 在本机（Impeller/Vulkan）上拿到的都是 0 帧，量不出「切主题卡一下」这种体感问题。
/// 帧耗时只有 Flutter 自己知道。
///
/// 用法：
///   flutter build apk --debug --dart-define=WM_FRAME_PROBE=true ...
///   adb logcat -c; <操作>; adb logcat -d -s flutter:I | grep FH
///
/// 输出一行一帧，只打「慢帧」（build 或 raster 超过 8 ms），
/// 另在每 60 帧打一条汇总，避免刷屏也避免漏掉持续时间长的卡顿。
class FrameProbe {
  const FrameProbe._();

  static const bool enabled = bool.fromEnvironment('WM_FRAME_PROBE');

  /// 单帧 build/raster 超过这个值就算可疑（60 Hz 下一帧 16.7 ms，留一半给对方）
  static const double _slowMs = 8;

  static int _frames = 0;
  static int _slow = 0;
  static double _worstBuild = 0;
  static double _worstRaster = 0;

  static void install() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    debugPrint('[FH] 帧探针已挂上');
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      _frames++;
      if (build > _worstBuild) _worstBuild = build;
      if (raster > _worstRaster) _worstRaster = raster;
      if (build > _slowMs || raster > _slowMs) {
        _slow++;
        debugPrint(
          '[FH] slow frame #$_frames build=${build.toStringAsFixed(1)}ms '
          'raster=${raster.toStringAsFixed(1)}ms',
        );
      }
      if (_frames % 60 == 0) {
        debugPrint(
          '[FH] 汇总 $_frames 帧，慢帧 $_slow，最差 build=${_worstBuild.toStringAsFixed(1)}ms '
          'raster=${_worstRaster.toStringAsFixed(1)}ms',
        );
      }
    }
  }
}
