import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/storage/app_cache.dart';

/// 缓存体检与清理。
///
/// 这一组测试盯的是**边界**，不是「删得快不快」：
///   * 只碰本应用自己生成的文件（第三方 SDK 的临时文件不归我们管）；
///   * 修好但没导出的成果（`out_*.png` / `fixed_*.mp4`）在**保护期内**一个都不能少；
///   * 但过了保护期的成果必须清 —— 它们已经不可达（App 重启后没有入口），
///     永久留着等于「保留 N 个未导出的成果」这句提示在骗人。
///
/// 第二条尤其要紧：用户修完图还没点保存时，成果只存在于临时目录。
/// 清理把它删了，界面还写着「已释放 1.2 MB」—— 假成功最难看的一种。
void main() {
  late Directory dir;
  late TempDirCacheStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wm_cache_test');
    store = TempDirCacheStore(cacheDirectory: () async => dir);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  File file(String name, int bytes, {Duration age = Duration.zero}) {
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(List<int>.filled(bytes, 0));
    // 造「老文件」只能改 mtime —— 保护期判断读的就是它
    if (age > Duration.zero) {
      f.setLastModifiedSync(DateTime.now().subtract(age));
    }
    return f;
  }

  group('体检', () {
    test('只统计本应用生成的文件', () async {
      file('in_1700000000000.png', 100);
      file('mask_1700000000000.png', 200);
      file('poster_1700000000000.png', 300);
      file('someone_else.tmp', 5000); // 第三方 SDK 的，不算

      final snapshot = await store.inspect();

      expect(snapshot.removableBytes, 600);
      expect(snapshot.keptBytes, 0);
      expect(snapshot.keptCount, 0);
    });

    test('未导出的成果单独计数，不进「可清理」', () async {
      file('out_1700000000000.png', 400);
      file('fixed_1700000000000.mp4', 900);
      file('in_1700000000000.png', 100);

      final snapshot = await store.inspect();

      expect(snapshot.removableBytes, 100, reason: 'in_ 是可再生的输入副本');
      expect(snapshot.keptBytes, 1300);
      expect(snapshot.keptCount, 2);
    });

    test('示例视频算缓存（能从 assets 重新落盘）', () async {
      file('sample_video.mp4', 1024);

      final snapshot = await store.inspect();

      expect(snapshot.removableBytes, 1024);
      expect(snapshot.keptCount, 0);
    });

    test('目录不存在时给空结果，不抛', () async {
      await dir.delete(recursive: true);

      final snapshot = await store.inspect();

      expect(snapshot.isEmpty, isTrue);
    });

    test('子目录不参与（第三方 SDK 的地盘）', () async {
      final sub = Directory('${dir.path}${Platform.pathSeparator}out_lib')
        ..createSync();
      File('${sub.path}${Platform.pathSeparator}out_x.png')
          .writeAsBytesSync(List<int>.filled(999, 0));

      final snapshot = await store.inspect();

      expect(snapshot.keptBytes, 0);
      expect(snapshot.removableBytes, 0);
    });

    test('成果的保护期：24 小时内的算保留，更早的算可清理', () async {
      // 刚修完、还没点保存
      file('out_fresh.png', 400, age: const Duration(hours: 1));
      // 昨天的成果：App 重启后已经没有任何入口能打开它
      file('out_stale.png', 600, age: const Duration(hours: 48));
      file('fixed_stale.mp4', 900, age: const Duration(days: 7));

      final snapshot = await store.inspect();

      expect(snapshot.keptCount, 1, reason: '只保护 1 小时前那一个');
      expect(snapshot.keptBytes, 400);
      expect(snapshot.removableBytes, 1500, reason: '600 + 900 已经不可达');
    });
  });

  group('清理', () {
    test('删掉可再生的，保住成果，字节数对得上', () async {
      final inputCopy = file('in_1700000000000.png', 100);
      final mask = file('mask_1700000000000.png', 200);
      final poster = file('poster_1700000000000.png', 300);
      final out = file('out_1700000000000.png', 400);
      final fixed = file('fixed_1700000000000.mp4', 900);
      final foreign = file('someone_else.tmp', 5000);

      final report = await store.clear();

      expect(report.freedBytes, 600);
      expect(report.keptCount, 2);
      expect(report.keptBytes, 1300);
      expect(report.failedCount, 0);

      expect(inputCopy.existsSync(), isFalse);
      expect(mask.existsSync(), isFalse);
      expect(poster.existsSync(), isFalse);
      expect(out.existsSync(), isTrue, reason: '修好的图还没导出，删了就找不回来');
      expect(fixed.existsSync(), isTrue, reason: '修好的视频还没导出，删了就找不回来');
      expect(foreign.existsSync(), isTrue, reason: '不是我们的文件，不许动');
    });

    test('清完再体检：可清理归零，保留数不变', () async {
      file('in_1700000000000.png', 100);
      file('fixed_1700000000000.mp4', 900);

      await store.clear();
      final after = await store.inspect();

      expect(after.removableBytes, 0);
      expect(after.keptBytes, 900);
      expect(after.keptCount, 1);
    });

    test('过期的成果真的被删掉，保护期内的一个不动', () async {
      final fresh = file('out_fresh.png', 400, age: const Duration(hours: 2));
      final stale = file('out_stale.png', 600, age: const Duration(days: 3));
      final staleVideo = file(
        'fixed_stale.mp4',
        900,
        age: const Duration(days: 3),
      );

      final report = await store.clear();

      expect(report.freedBytes, 1500);
      expect(report.keptBytes, 400, reason: '保护期内的成果仍占 400');
      expect(report.keptCount, 1);

      expect(fresh.existsSync(), isTrue, reason: '2 小时前的成果，用户可能还没导出');
      expect(stale.existsSync(), isFalse, reason: '3 天前的成果已经不可达');
      expect(staleVideo.existsSync(), isFalse);
    });

    test('没有可清理的东西时，报告是 0 而不是报错', () async {
      file('fixed_1700000000000.mp4', 900);

      final report = await store.clear();

      expect(report.freedBytes, 0);
      expect(report.keptCount, 1);
      expect(report.failedCount, 0);
    });
  });
}
