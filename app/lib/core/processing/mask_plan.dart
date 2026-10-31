import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 水印在整段素材里的运动方式。
///
/// 第一版只会产出 [staticFixed]；其余两种是为动态水印预留的 —— 现在留好，
/// 以后不用回头改整条链路（技术方案 3.3.9 的核心结论）。
enum WatermarkMotion {
  /// 位置固定：一个 Mask 用全片
  staticFixed,

  /// 位置漂移：需要逐帧轨迹（[MaskPlan.perFrameBox]）
  drifting,

  /// 形变 / 遮挡：第一版不支持，处理入口应直接返回明确错误
  occluded,
}

enum TrackQuality {
  good,

  /// 轨迹与真实位置偏离，结果可能带残影
  drifted,

  /// 追踪置信度崩溃，必须让用户补一个关键帧，不能静默产出残次品
  needsKeyframe,
}

/// 用户在某一时刻框出的水印位置。
@immutable
class Keyframe {
  const Keyframe({
    required this.time,
    required this.box,
    this.confidence = 1.0,
  });

  final Duration time;

  /// **归一化坐标 0..1**（相对源帧），与分辨率、旋转方向无关。
  /// 用像素坐标存，换分辨率后整条轨迹就作废了。
  final Rect box;

  /// 1.0 = 人工标注；追踪补出来的关键帧 < 1
  final double confidence;

  @override
  String toString() => 'Keyframe($time, $box, conf=$confidence)';
}

/// 逐帧修复计划。
///
/// 替代早期设计里的单个 `maskPath` —— 那个形状只能表达静态水印。
@immutable
class MaskPlan {
  const MaskPlan({
    required this.motion,
    this.keyframes = const <Keyframe>[],
    this.perFrameBox,
    this.staticMaskPath,
    this.quality = TrackQuality.good,
  });

  /// 图片 / 静态水印视频的唯一构造路径：一张 Mask 用到底。
  factory MaskPlan.fixed({
    required String maskPath,
    TrackQuality quality = TrackQuality.good,
  }) {
    return MaskPlan(
      motion: WatermarkMotion.staticFixed,
      staticMaskPath: maskPath,
      quality: quality,
    );
  }

  final WatermarkMotion motion;

  /// 用户标注的关键帧 + 追踪失败时补的
  final List<Keyframe> keyframes;

  /// 长度必须等于总帧数；[WatermarkMotion.staticFixed] 时为 null
  final List<Rect>? perFrameBox;

  /// 仅 [WatermarkMotion.staticFixed] 时使用
  final String? staticMaskPath;

  final TrackQuality quality;

  /// 长度对不上是这类实现最常见的崩溃点，所以在入口处断言而不是等 native 崩。
  ///
  /// [frameCount] 为 null 表示图片（无帧概念），只校验静态分支。
  void validateAgainst({int? frameCount, required Size? mediaSize}) {
    switch (motion) {
      case WatermarkMotion.staticFixed:
        assert(
          staticMaskPath != null && staticMaskPath!.isNotEmpty,
          'staticFixed 必须给 staticMaskPath',
        );
        if (perFrameBox != null) {
          assert(
            frameCount == null || perFrameBox!.length == frameCount,
            'perFrameBox 长度 ${perFrameBox!.length} != 总帧数 $frameCount',
          );
        }
      case WatermarkMotion.drifting:
        assert(keyframes.length >= 2, 'drifting 至少需要 2 个关键帧');
        assert(
          perFrameBox != null && perFrameBox!.isNotEmpty,
          'drifting 必须给出逐帧轨迹',
        );
        assert(
          frameCount == null || perFrameBox!.length == frameCount,
          'perFrameBox 长度 ${perFrameBox!.length} != 总帧数 $frameCount',
        );
      case WatermarkMotion.occluded:
        // 不抛：由上层把它翻译成「不支持」的业务错误码
        break;
    }
    assert(
      mediaSize == null || mediaSize.width > 0 && mediaSize.height > 0,
      '素材尺寸非法：$mediaSize',
    );
  }

  /// 给日志/错误信息用的一句话描述
  String describe() {
    switch (motion) {
      case WatermarkMotion.staticFixed:
        return '静止水印 · 单 Mask';
      case WatermarkMotion.drifting:
        return '逐帧漂移 · ${keyframes.length} 个关键帧'
            '${quality == TrackQuality.needsKeyframe ? '（追踪不可靠）' : ''}';
      case WatermarkMotion.occluded:
        return '形变水印 · 暂不支持';
    }
  }
}
