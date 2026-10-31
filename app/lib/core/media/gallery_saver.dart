import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../processing/processing_error.dart';
import 'media_channel.dart';

part 'gallery_saver.g.dart';

/// 把处理结果写进系统相册（Pictures/水印工坊、Movies/水印工坊）。
///
/// 单独一个服务而不是塞进 [WatermarkProcessor]：修复是纯计算，存相册是系统副作用，
/// 两者的失败语义完全不同（前者该重试，后者该提示用户）—— 混在一个接口里以后会互相拖累。
class GallerySaver {
  const GallerySaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kMediaChannelName);

  final MethodChannel _channel;

  /// 返回 MediaStore 的 `content://` URI。
  Future<String> save({
    required String sourcePath,
    String? displayName,
  }) => _invoke('saveImage', sourcePath: sourcePath, displayName: displayName);

  /// 视频版：写到 `Movies/水印工坊`。
  ///
  /// 之前只有图片能保存，视频修完只留在临时目录，重启后被系统清掉 ——
  /// 用户等于「修了但拿不出来」。
  Future<String> saveVideo({
    required String sourcePath,
    String? displayName,
  }) => _invoke('saveVideo', sourcePath: sourcePath, displayName: displayName);

  Future<String> _invoke(
    String method, {
    required String sourcePath,
    String? displayName,
  }) async {
    try {
      final uri = await _channel.invokeMethod<String>(method, <String, Object?>{
        'sourcePath': sourcePath,
        'displayName': ?displayName,
      });
      if (uri == null || uri.isEmpty) {
        throw const ProcessingException(
          ProcessingErrorCode.nativeFailure,
          detail: '相册保存没有返回 URI',
        );
      }
      return uri;
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
GallerySaver gallerySaver(Ref ref) => const GallerySaver();
