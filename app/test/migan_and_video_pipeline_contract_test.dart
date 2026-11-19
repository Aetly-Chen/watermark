import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';
import 'package:watermark_remover/core/processing/mask_plan.dart';
import 'package:watermark_remover/core/processing/processing_request.dart';

/// 端侧 AI 去水印（MI-GAN ONNX）与视频转码修复链路契约测试。
///
/// 这类跨语言（Dart ↔ Kotlin ↔ ONNX 资产 ↔ Gradle 配置）的核心约束
/// 单靠 Dart 编译器查不出来，必须显式守住关键契约，防止回退或漏打包。
void main() {
  test('MI-GAN ONNX 模型资产存在且字节数精确为 28,079,181', () {
    final modelFile = File('android/app/src/main/assets/models/migan_pipeline_v2.onnx');
    expect(
      modelFile.existsSync(),
      isTrue,
      reason: '缺少 MI-GAN 模型文件，请检查是否在 app/ 目录运行测试或模型是否已放入 assets/models/',
    );
    expect(modelFile.lengthSync(), 28079181);
  });

  test('build.gradle.kts 已引入 onnxruntime-android 并排除非 arm64 jniLibs', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('com.microsoft.onnxruntime:onnxruntime-android:'));
    expect(gradle, contains('"lib/x86/**"'));
    expect(gradle, contains('"lib/x86_64/**"'));
    expect(gradle, contains('"lib/armeabi-v7a/**"'));
  });

  test('MiganInpainter.kt 守住 UINT8 类型、Arena 关闭与 Mask 极性反转契约', () {
    final migan = File(
      'android/app/src/main/kotlin/cn/shuiyin/watermark_remover/media/MiganInpainter.kt',
    ).readAsStringSync();
    expect(migan, contains('OnnxJavaType.UINT8'));
    expect(migan, contains('setCPUArenaAllocator(false)'));
    // MI-GAN 约定：待修复像素写入 0，保留区域写入 255
    expect(migan, contains('maskChw.put(0.toByte())'));
    expect(migan, contains('maskChw.put(255.toByte())'));
  });

  test('VideoProcessor.kt 包含防绿屏、防编码器死锁与 UV 尾字节保护逻辑', () {
    final video = File(
      'android/app/src/main/kotlin/cn/shuiyin/watermark_remover/media/VideoProcessor.kt',
    ).readAsStringSync();
    expect(video, contains('origYuvValid'));
    expect(video, contains('dequeueEncoderInputWithDrain'));
    expect(video, contains('sibBuf.get(sibIdx)'));
    expect(video, contains('CodecHelper.openDecoder'));
    expect(video, contains('CodecHelper.openEncoder'));
  });

  test('ProcessingRequest 默认启用 auto 模式，VideoRepairResult 正确解析 engine 与 audioSkipped', () {
    final req = ProcessingRequest(
      taskId: 't-auto',
      inputPath: '/in.png',
      outputPath: '/out.png',
      mediaKind: MediaKind.image,
      plan: MaskPlan.fixed(maskPath: '/mask.png'),
    );
    expect(req.toChannelMap()['method'], 'auto');

    final result = VideoRepairResult.fromChannelMap(<String, Object?>{
      'outputPath': '/tmp/out.mp4',
      'width': 1920,
      'height': 1080,
      'rotation': 0,
      'frames': 120,
      'skippedFrames': 0,
      'videoBytes': 2000000,
      'audioBytes': 0,
      'hasAudio': false,
      'maskPixels': 3200,
      'sizeBytes': 2050000,
      'elapsedMs': 4200,
      'engine': 'migan',
      'audioSkipped': true,
    });
    expect(result.engine, 'migan');
    expect(result.audioSkipped, isTrue);

    final legacy = VideoRepairResult.fromChannelMap(<String, Object?>{
      'outputPath': '/tmp/legacy.mp4',
    });
    expect(legacy.engine, '');
    expect(legacy.audioSkipped, isFalse);
  });
}
