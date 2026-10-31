import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../media/media_channel.dart';
import 'mask_plan.dart';
import 'processing_error.dart';
import 'processing_request.dart';
import 'processing_result.dart';
import 'watermark_processor.dart';

part 'local_basic_image_processor.g.dart';

/// 本地基础引擎：走 MethodChannel 到 Kotlin + OpenCV。
///
/// 这一层只做三件事：参数校验 → 调通道 → 把 PlatformException 翻译成业务错误码。
/// 任何像素操作都不在这里 —— 通道两边各管一段，边界清楚才不会出现「一半 Dart 一半 Kotlin」的糊涂逻辑。
class LocalBasicImageProcessor implements WatermarkProcessor {
  LocalBasicImageProcessor({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kMediaChannelName);

  final MethodChannel _channel;

  @override
  ProcessingMode get mode => ProcessingMode.localBasic;

  @override
  Future<ProcessingResult> process(
    ProcessingRequest request, {
    ProgressCallback? onProgress,
  }) async {
    if (request.mediaKind != MediaKind.image) {
      throw const ProcessingException(
        ProcessingErrorCode.unsupportedFormat,
        detail: '当前只接了图片链路，视频引擎还没实现',
      );
    }
    if (request.plan.motion == WatermarkMotion.occluded) {
      throw const ProcessingException(
        ProcessingErrorCode.unsupportedFormat,
        detail: '形变水印第一版不支持',
      );
    }
    // 长度/字段校验放在过通道之前，省得 native 崩了才发现是数据问题
    request.plan.validateAgainst(frameCount: null, mediaSize: null);

    onProgress?.call(
      const ProcessingProgress(stage: ProcessingStage.repairing, value: 0.15),
    );

    final stopwatch = Stopwatch()..start();
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'inpaintImage',
        request.toChannelMap(),
      );
      stopwatch.stop();

      final outputPath = raw?['outputPath'] as String?;
      if (outputPath == null || outputPath.isEmpty) {
        throw const ProcessingException(
          ProcessingErrorCode.nativeFailure,
          detail: '通道返回没有 outputPath',
        );
      }

      onProgress?.call(
        const ProcessingProgress(stage: ProcessingStage.finalizing, value: 0.95),
      );

      return ProcessingResult(
        outputPath: outputPath,
        outputWidth: (raw?['width'] as num?)?.toInt() ?? 0,
        outputHeight: (raw?['height'] as num?)?.toInt() ?? 0,
        elapsed: Duration(
          milliseconds: (raw?['elapsedMs'] as num?)?.toInt() ?? stopwatch.elapsedMilliseconds,
        ),
      );
    } on PlatformException catch (error) {
      throw ProcessingException(
        ProcessingErrorCode.fromCode(error.code),
        detail: error.message,
      );
    } on MissingPluginException {
      throw const ProcessingException(
        ProcessingErrorCode.nativeFailure,
        detail: '平台通道未注册（Kotlin 侧没接上，或跑在不支持的平台上）',
      );
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object?>{
        'taskId': taskId,
      });
    } on MissingPluginException {
      // 图片任务是同步完成的，没有可取消的东西；视频引擎接入后再补
    } on PlatformException {
      // 取消是尽力而为，失败不该打断调用方
    }
  }
}

/// 全局引擎实例。将来加 [ProcessingMode.localAi] 时在这里按 mode 分发即可，
/// UI 只依赖 `WatermarkProcessor` 抽象，不需要知道具体实现。
@Riverpod(keepAlive: true)
WatermarkProcessor watermarkProcessor(Ref ref) => LocalBasicImageProcessor();
