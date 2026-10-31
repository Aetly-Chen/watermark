import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'thumbnail.dart';

/// 历史记录的缩略图。
///
/// 存在 **`<应用支持目录>/thumbs/`**，不是临时目录 —— 临时目录会被系统清，
/// 也会被「清理缓存」清（见 `core/storage/app_cache.dart`），而缩略图是记录的一部分。
///
/// 文件名用记录 id（`i-<微秒>` / `v-<微秒>`），一条记录一张，不覆盖别人。
class ThumbnailStore {
  const ThumbnailStore({this.directory});

  /// 只为测试注入：单测里没有 platform channel。
  final Future<Directory> Function()? directory;

  static const String dirName = 'thumbs';

  Future<Directory> _dir() async {
    final base = directory != null
        ? await directory!()
        : await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 非法文件名字符换成 `_`。id 目前都是我们自己生成的，这一步是防御。
  static String _safe(String id) => id.replaceAll(RegExp(r'[^\w.-]'), '_');

  /// 生成并落盘。失败返回 null —— 调用方照常写历史，只是没缩略图。
  Future<String?> save(String id, Uint8List source) async {
    try {
      final bytes = await encodeThumbnail(source);
      if (bytes == null) return null;
      final dir = await _dir();
      final file = File('${dir.path}${Platform.pathSeparator}${_safe(id)}.png');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object catch (error) {
      debugPrint('[thumb] 落盘失败：$error');
      return null;
    }
  }

  /// 文件还在不在。列表里直接用 `Image.file` 也行（它有 errorBuilder），
  /// 但先判一下能避免每行都触发一次异步解码失败。
  static bool exists(String? path) {
    if (path == null || path.isEmpty) return false;
    return File(path).existsSync();
  }

  Future<void> remove(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on Object catch (error) {
      debugPrint('[thumb] 删除失败：$error');
    }
  }

  /// 清空历史时一起清掉缩略图，否则会留下一堆没人引用的孤儿文件。
  Future<void> clearAll() async {
    try {
      final dir = await _dir();
      if (!dir.existsSync()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
          } on Object catch (error) {
            debugPrint('[thumb] 删除失败 ${entity.path}: $error');
          }
        }
      }
    } on Object catch (error) {
      debugPrint('[thumb] 清空失败：$error');
    }
  }
}

final Provider<ThumbnailStore> thumbnailStoreProvider = Provider(
  (ref) => const ThumbnailStore(),
);
