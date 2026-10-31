import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/media/thumbnail_store.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../domain/history_item.dart';

/// 历史记录的小图。列表（56×56）和详情页（16:9）共用。
///
/// **尺寸由父级决定**，这里只负责「有图就显示、没图就退回图标」。
/// 三种没图的情况都会走到图标兜底，而且都必须正常显示，不是异常路径：
///   1. 这条记录来自加缩略图之前的版本（`thumbPath == null`）；
///   2. 缩略图生成失败（解码不了那种格式）；
///   3. 文件被用户清数据/系统清理删掉了。
///
/// 所以在 `Image.file` 上挂了 `errorBuilder`，同时先用 `existsSync` 挡一次 ——
/// 后者避免每行都触发一次注定失败的异步解码。
class HistoryThumb extends StatelessWidget {
  const HistoryThumb({
    required this.item,
    super.key,
    this.radius = 10,
    this.iconSize = 22,
    this.cacheWidth = 168,
  });

  final HistoryItem item;
  final double radius;
  final double iconSize;

  /// 解码宽度（px）。缩略图源只有 320 宽，但列表里显示 56 ——
  /// 按显示尺寸解码，50 行一起滚的时候省的是解码内存。
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isVideo = item.kind == HistoryKind.video;
    final path = item.thumbPath;
    final hasFile = ThumbnailStore.exists(path);

    final fallback = Center(
      child: Icon(
        isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: t.cream.withValues(alpha: 0.7),
        size: iconSize,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: t.media,
        child: hasFile
            ? Image.file(
                File(path!),
                fit: BoxFit.cover,
                cacheWidth: cacheWidth,
                errorBuilder: (context, error, stack) => fallback,
              )
            : fallback,
      ),
    );
  }
}
