import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/thumbnail.dart';
import 'package:watermark_remover/core/media/thumbnail_store.dart';

/// 缩略图生成与落盘。
///
/// 为什么值得测：`encodeThumbnail` 是唯一一处「真的调用 `dart:ui` 解码」的地方，
/// 它在测试环境里很容易静默挂死（不是抛异常，是永远不返回）。所以这一组必须用
/// `test()` + `TestWidgetsFlutterBinding.ensureInitialized()`，不能塞进 `testWidgets`。
///
/// 断言的重点是**尺寸真的被压下来了**，而不是「代码跑了没报错」——
/// 缩略图如果跟原图一样大，功能等于没做，但界面上看不出来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 造一张纯色 PNG。比在仓库里塞二进制样本清楚，而且尺寸可控。
  Future<Uint8List> solidPng(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3366CC),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  group('encodeThumbnail', () {
    test('大图被压到 maxWidth，输出仍是可解码的 PNG', () async {
      final source = await solidPng(1200, 900);
      final out = await encodeThumbnail(source, maxWidth: 320);

      expect(out, isNotNull);
      expect(out!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG 魔数');

      final image = await decode(out);
      expect(image.width, 320);
      expect(image.height, 240, reason: '等比缩放，高度跟着变');
      image.dispose();

      expect(out.length, lessThan(source.length));
    });

    test('小图不被放大（allowUpscaling=false）', () async {
      final source = await solidPng(120, 80);
      final out = await encodeThumbnail(source, maxWidth: 320);

      final image = await decode(out!);
      expect(image.width, 120, reason: '拉大只会变糊且更占地方');
      image.dispose();
    });

    test('坏字节返回 null，不抛', () async {
      final out = await encodeThumbnail(
        Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      expect(out, isNull);
    });
  });

  group('ThumbnailStore', () {
    late Directory dir;
    late ThumbnailStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wm_thumb_test');
      store = ThumbnailStore(directory: () async => dir);
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('存进 thumbs/，路径可回读，文件真的在', () async {
      final source = await solidPng(600, 400);
      final path = await store.save('i-1700000000000', source);

      expect(path, isNotNull);
      expect(path, contains('thumbs'));
      expect(ThumbnailStore.exists(path), isTrue);
      expect(File(path!).lengthSync(), greaterThan(0));
    });

    test('同 id 覆盖（重跑不会堆文件）', () async {
      final source = await solidPng(400, 300);
      final a = await store.save('i-1', source);
      final b = await store.save('i-1', source);

      expect(a, b);
      expect(
        dir.listSync(recursive: true).whereType<File>().length,
        1,
      );
    });

    test('非法文件名被替换，不会跑到子目录去', () async {
      final source = await solidPng(200, 200);
      final path = await store.save('i/../../evil', source);

      expect(path, isNotNull);
      final file = File(path!);
      expect(file.parent.path, endsWith('thumbs'));
      expect(file.existsSync(), isTrue);
    });

    test('remove 与 clearAll 都真的删文件', () async {
      final source = await solidPng(200, 200);
      final a = await store.save('i-1', source);
      final b = await store.save('i-2', source);

      await store.remove(a);
      expect(ThumbnailStore.exists(a), isFalse);
      expect(ThumbnailStore.exists(b), isTrue);

      await store.clearAll();
      expect(ThumbnailStore.exists(b), isFalse);
    });

    test('exists 对 null / 空串 / 不存在的路径都返回 false', () {
      expect(ThumbnailStore.exists(null), isFalse);
      expect(ThumbnailStore.exists(''), isFalse);
      expect(ThumbnailStore.exists('/definitely/not/here.png'), isFalse);
    });
  });
}
