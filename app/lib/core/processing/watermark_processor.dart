import 'processing_request.dart';
import 'processing_result.dart';

/// 处理阶段。
///
/// 视频任务必须把这些阶段分开报进度，否则长任务在 UI 上看起来像卡死
/// （技术方案 §5.6 的约定）；图片只有一次修复，会直接跳过前两个。
enum ProcessingStage {
  /// 分析镜头运动（视频动态水印分诊）
  analyzing('分析镜头运动'),

  /// 追踪水印轨迹
  tracking('追踪水印轨迹'),

  /// 逐帧 / 单帧修复
  repairing('修复画面'),

  /// 编码封装
  encoding('编码与封装'),

  /// 收尾（落盘、清理临时文件）
  finalizing('收尾');

  const ProcessingStage(this.label);

  final String label;
}

class ProcessingProgress {
  const ProcessingProgress({required this.stage, required this.value});

  final ProcessingStage stage;

  /// 0..1，整任务口径
  final double value;

  @override
  String toString() => '${stage.label} ${(value * 100).toStringAsFixed(0)}%';
}

typedef ProgressCallback = void Function(ProcessingProgress progress);

/// 处理引擎的统一抽象。
///
/// 用回调传进度而不是 Stream：单个任务一次调用就结束，回调更薄；
/// UI 侧由 Riverpod 的 Notifier 把回调转成 state，不需要额外的 StreamController 生命周期管理。
/// 将来做视频时如果确实需要多订阅者，再在实现内部包一层 Stream 即可。
abstract interface class WatermarkProcessor {
  ProcessingMode get mode;

  /// 不支持当前请求时抛 [ProcessingException]。
  Future<ProcessingResult> process(
    ProcessingRequest request, {
    ProgressCallback? onProgress,
  });

  /// 取消。没有进行中的任务时是幂等的空操作。
  Future<void> cancel(String taskId);
}
