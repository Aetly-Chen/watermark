import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 预览播放器的通道名。必须与原生 `VideoPreviewPlugin.CHANNEL` 一致。
const String kVideoPreviewChannel = 'cn.shuiyin.watermark_remover/video_preview';

/// 一次预览会话：Flutter 侧拿到的纹理 id 与视频元信息。
///
/// 画面通过 `Texture(textureId:)` 显示 —— 原生用 `MediaPlayer` 把帧画进
/// SurfaceTexture，Flutter 只负责把这块纹理贴到 widget 上。
@immutable
class VideoPreviewHandle {
  const VideoPreviewHandle({
    required this.textureId,
    required this.width,
    required this.height,
    required this.duration,
  });

  final int textureId;

  /// 视频像素尺寸。为 0 时说明原生没报到尺寸，按 16:9 兜底。
  final int width;
  final int height;
  final Duration duration;

  double get aspectRatio => (width <= 0 || height <= 0) ? 16 / 9 : width / height;

  static VideoPreviewHandle fromChannelMap(Map<String, Object?> raw) {
    return VideoPreviewHandle(
      textureId: (raw['textureId'] as num?)?.toInt() ?? -1,
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      duration: Duration(
        milliseconds: (raw['durationMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  @override
  String toString() =>
      'VideoPreviewHandle(texture=$textureId, ${width}x$height, $duration)';
}

/// 播放器打不开。
///
/// [message] 来自原生（例如 `IllegalStateException: ...`），只用于日志；
/// 界面上一律用固定话术，不把异常类型甩给用户。
class VideoPreviewException implements Exception {
  const VideoPreviewException(this.code, this.detail);

  final String code;
  final String? detail;

  @override
  String toString() => 'VideoPreviewException($code): $detail';
}

/// 原生预览播放器的 Dart 侧封装。
///
/// 为什么不是 `video_player`：这台华为机上 ExoPlayer 会选中
/// `OMX.hisi.video.decoder.avc` 并初始化失败（详见 Kotlin 侧注释），
/// 而 `MediaPlayer` 走系统播放器同一条通路，同一个文件能正常解码。
class VideoPreviewer {
  const VideoPreviewer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kVideoPreviewChannel);

  final MethodChannel _channel;

  /// 打开并**自动开始播放**（原生 setOnPrepared 里就 start 了）。
  Future<VideoPreviewHandle> open(String path) async {
    final raw = await _guard(
      () => _channel.invokeMapMethod<String, Object?>('open', {'path': path}),
    );
    if (raw == null) {
      throw const VideoPreviewException('preview_failed', '原生没有返回数据');
    }
    final handle = VideoPreviewHandle.fromChannelMap(raw);
    if (handle.textureId < 0) {
      throw const VideoPreviewException('preview_failed', '没有拿到纹理 id');
    }
    return handle;
  }

  Future<void> play() => _guard(() => _channel.invokeMethod<void>('play'));

  Future<void> pause() => _guard(() => _channel.invokeMethod<void>('pause'));

  Future<void> seek(Duration position) => _guard(
    () => _channel.invokeMethod<void>('seek', {
      'ms': position.inMilliseconds,
    }),
  );

  Future<Duration> position() async {
    final ms = await _guard(() => _channel.invokeMethod<int>('position'));
    return Duration(milliseconds: ms ?? 0);
  }

  Future<void> close() => _guard(() => _channel.invokeMethod<void>('close'));

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (error) {
      throw VideoPreviewException(error.code, error.message);
    } on MissingPluginException {
      throw const VideoPreviewException('preview_failed', '平台通道未注册');
    }
  }
}

final Provider<VideoPreviewer> videoPreviewerProvider = Provider(
  (ref) => const VideoPreviewer(),
);
