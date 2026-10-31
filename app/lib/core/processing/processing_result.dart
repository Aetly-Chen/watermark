import 'package:flutter/foundation.dart';

/// 处理结果。
@immutable
class ProcessingResult {
  const ProcessingResult({
    required this.outputPath,
    required this.outputWidth,
    required this.outputHeight,
    required this.elapsed,
  });

  final String outputPath;
  final int outputWidth;
  final int outputHeight;

  /// 引擎耗时（不含 Dart 侧的 Mask 生成）
  final Duration elapsed;

  String get sizeLabel => '$outputWidth × $outputHeight';
}
