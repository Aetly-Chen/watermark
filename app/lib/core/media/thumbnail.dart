import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 把一张图的字节压成小尺寸 PNG，给历史列表/详情页当缩略图。
///
/// 为什么不用原图：原图动辄 2~5 MB，50 条历史就是几百 MB。缩略图 320 宽
/// （列表里显示 56、详情页 200，2 倍屏都够）通常几十 KB。
///
/// 为什么存成文件而不是 base64 塞进 JSON：`history.json` 会因为缩略图变成几 MB，
/// 每次读写都要整体解析 —— 一个坏字节就能让整页历史打不开（见 `FileHistoryStore`
/// 的宽容解析，那是兜底不是借口）。
///
/// ⚠ `toByteData` 只支持 PNG，没有 JPEG 选项。所以体积是靠**尺寸**压下来的，
/// 不是靠质量参数。
/// 缩略图最大宽度。**实现和测试共用这一个值** —— 分开写死 320 的话，
/// 哪天调了这里忘了那里，测试还绿着却在验证一个已经不成立的事实。
const int kThumbnailMaxWidth = 320;

Future<Uint8List?> encodeThumbnail(
  Uint8List source, {
  int maxWidth = kThumbnailMaxWidth,
}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    // ⚠ `allowUpscaling` 默认是 **true**（实测 120 宽的图会被拉到 320，反而更大）。
    // 必须显式关掉：小图原样留着，缩略图不该比原图占地方。
    codec = await ui.instantiateImageCodec(
      source,
      targetWidth: maxWidth,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List();
  } on Object catch (error) {
    // 解不出来（格式不支持、字节被截断）不是致命错误：没缩略图就用图标兜底。
    debugPrint('[thumb] 生成失败：$error');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
