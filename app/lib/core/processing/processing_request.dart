import 'package:flutter/foundation.dart';

import 'mask_plan.dart';

enum MediaKind { image, video }

/// 处理引擎。MVP 只有 [localBasic]，另外两个是接口层的预留，
/// 让 UI 将来可以在不改变调用方的前提下切换实现。
enum ProcessingMode { localBasic, localAi, cloudAi }

enum OutputQuality {
  standard('标准'),
  high('高清');

  const OutputQuality(this.label);

  final String label;
}

/// 一次处理请求。
///
/// 注意 `plan` 是 [MaskPlan] 而不是单个 maskPath —— 见 mask_plan.dart 的注释。
@immutable
class ProcessingRequest {
  const ProcessingRequest({
    required this.taskId,
    required this.inputPath,
    required this.outputPath,
    required this.mediaKind,
    required this.plan,
    this.mode = ProcessingMode.localBasic,
    this.outputQuality = OutputQuality.standard,
    this.refineMask = false,
    this.radius,
  });

  final String taskId;

  /// 已按显示方向「压平」的输入文件（EXIF 旋转在 Dart 侧已消解，见 mask_composer）
  final String inputPath;

  final String outputPath;
  final MediaKind mediaKind;
  final ProcessingMode mode;
  final MaskPlan plan;
  final OutputQuality outputQuality;

  /// 修复半径（像素）的**显式覆盖**。null = 按质量档位推导。
  ///
  /// 一开始它只由 [outputQuality] 推导，界面上没有任何入口 ——
  /// 而原型上明明有「修复强度」这一项。参数在引擎里早就通了，差的是一个滑块。
  final int? radius;

  /// Telea 的邻域半径。越大填得越「干净」，但周围细节会被一起抹平。
  int get inpaintRadius =>
      radius ?? (outputQuality == OutputQuality.high ? 8 : 6);

  /// 是否在框内细分 Mask（**默认关**）。
  ///
  /// 实测结论（2026-10-17，华为 JER-AN10）：对 `cafe.jpg` 用一个大十倍的框，
  /// 细分把 Mask 从 28728 px 缩到 9996 px（34%），但**水印条带之外的改动像素
  /// 一点没少（3356 → 3356）**。原因是判据假设「高频 = 水印」，而木纹背景同样高频：
  /// 细分删掉的是平坦区域（那些地方修了本来也看不出来），真正造成涂抹的高频纹理全被留下。
  ///
  /// 所以它现在是**实验开关**，不是功能：留着是因为管道（参数、阈值、三道保险、A/B 用例）
  /// 在做「文字级检测」时可以直接复用；真要用它解决问题，判据得换成
  /// top-hat / 笔画宽度 / 连通域长宽比这类文字特征，或者直接上 LaMa。
  final bool refineMask;

  Map<String, Object?> toChannelMap() => <String, Object?>{
    'taskId': taskId,
    'inputPath': inputPath,
    'maskPath': plan.staticMaskPath,
    'outputPath': outputPath,
    'radius': inpaintRadius,
    'method': 'telea',
    'refine': refineMask,
  };
}
