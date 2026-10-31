import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../processing/processing_error.dart';
import 'media_channel.dart';

part 'video_probe.g.dart';

/// 视频元数据。
///
/// 两个尺寸必须分开存：
/// - [width]/[height] 是**编码尺寸**，帧解码出来也是这个尺寸；
/// - [displayWidth]/[displayHeight] 是按旋转交换过的**用户看到的尺寸**。
///
/// 竖拍视频常见「1920x1080 + rotation=90」，把这两个搞混，框选一定歪。
@immutable
class VideoMeta {
  const VideoMeta({
    required this.path,
    required this.width,
    required this.height,
    required this.rotation,
    required this.displayWidth,
    required this.displayHeight,
    required this.duration,
    required this.hasAudio,
    required this.sizeBytes,
  });

  factory VideoMeta.fromChannelMap(Map<String, Object?> map) => VideoMeta(
    path: map['path'] as String? ?? '',
    width: (map['width'] as num?)?.toInt() ?? 0,
    height: (map['height'] as num?)?.toInt() ?? 0,
    rotation: (map['rotation'] as num?)?.toInt() ?? 0,
    displayWidth: (map['displayWidth'] as num?)?.toInt() ?? 0,
    displayHeight: (map['displayHeight'] as num?)?.toInt() ?? 0,
    duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
    hasAudio: map['hasAudio'] as bool? ?? false,
    sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
  );

  final String path;
  final int width;
  final int height;
  final int rotation;
  final int displayWidth;
  final int displayHeight;
  final Duration duration;
  final bool hasAudio;
  final int sizeBytes;

  bool get isRotated => rotation == 90 || rotation == 270;

  String get resolutionLabel => '$displayWidth × $displayHeight';

  String get durationLabel {
    final total = duration.inMilliseconds ~/ 1000;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get sizeLabel {
    if (sizeBytes <= 0) return '—';
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(sizeBytes / 1024).round()} KB';
  }
}

/// 封面帧：一条落到磁盘的 PNG + 它的真实像素尺寸。
@immutable
class VideoFrame {
  const VideoFrame({
    required this.path,
    required this.width,
    required this.height,
    required this.elapsed,
  });

  final String path;
  final int width;
  final int height;
  final Duration elapsed;
}

/// 视频探测（元数据 + 封面帧）。**只读，不碰解码管线**。
class VideoProbe {
  const VideoProbe({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kMediaChannelName);

  final MethodChannel _channel;

  Future<VideoMeta> probe(String path) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('probeVideo', {
        'path': path,
      });
      if (raw == null) {
        throw const ProcessingException(
          ProcessingErrorCode.decodeFailed,
          detail: '探测视频没有返回数据',
        );
      }
      return VideoMeta.fromChannelMap(raw);
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
    }
  }

  Future<VideoFrame> extractFrame({
    required String path,
    required String outputPath,
    Duration position = Duration.zero,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('extractVideoFrame', {
        'path': path,
        'outputPath': outputPath,
        'positionMs': position.inMilliseconds,
      });
      final framePath = raw?['framePath'] as String?;
      if (framePath == null || framePath.isEmpty) {
        throw const ProcessingException(
          ProcessingErrorCode.decodeFailed,
          detail: '取封面帧没有返回路径',
        );
      }
      return VideoFrame(
        path: framePath,
        width: (raw?['width'] as num?)?.toInt() ?? 0,
        height: (raw?['height'] as num?)?.toInt() ?? 0,
        elapsed: Duration(milliseconds: (raw?['elapsedMs'] as num?)?.toInt() ?? 0),
      );
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
    }
  }
}

@Riverpod(keepAlive: true)
VideoProbe videoProbe(Ref ref) => const VideoProbe();
