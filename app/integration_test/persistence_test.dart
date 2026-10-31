import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watermark_remover/core/media/gallery_saver.dart';
import 'package:watermark_remover/core/media/thumbnail.dart';
import 'package:watermark_remover/core/media/thumbnail_store.dart';
import 'package:watermark_remover/core/theme/theme_mode_store.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';
import 'package:watermark_remover/features/image_editor/application/image_edit_controller.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';

/// 真机集成测试：**持久化链路**。
///
/// 单测能证明「控制器会调 store」，但它证明不了这三件事：
///   1. `history.json` 真的落在磁盘上、内容是完整的一条记录；
///   2. 缩略图文件真的生成了、真的能解码、尺寸真的被压到 320；
///   3. 换个 store 实例（≈进程重启）还能读回同样的东西。
///
/// 这些只有真跑一次才知道。之前一直挂在「真机端到端未验」里。
///
/// 隔离：store 全部注入**临时目录**，不碰 App 真实的 `history.json` ——
/// 否则跑一次测试就给用户的历史里塞一条假记录（干过这种事的教训写在 SOUL.md）。
///
/// 跑法：
///   flutter test integration_test/persistence_test.dart -d DEVICE_ID
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wm_persist');
  });

  tearDown(() async {
    // 自己的烂摊子自己收：临时目录里有 input/mask/output/缩略图/history.json
    if (tmp.existsSync()) {
      try {
        await tmp.delete(recursive: true);
      } on Object catch (error) {
        debugPrint('ITEST_WARN 临时目录没删掉 ${tmp.path}: $error');
      }
    }
  });

  FileHistoryStore historyStore() =>
      FileHistoryStore(directory: () async => tmp);
  ThumbnailStore thumbnailStore() =>
      ThumbnailStore(directory: () async => tmp);

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      historyStoreProvider.overrideWithValue(historyStore()),
      thumbnailStoreProvider.overrideWithValue(thumbnailStore()),
    ],
  );

  /// `_recordSuccess` 是 fire-and-forget（写盘失败不该把成功的修复变成失败），
  /// 所以 run() 返回时历史可能还没落盘 —— 只能等，不能立刻断言。
  Future<List<HistoryItem>> waitForHistory({
    int expectAtLeast = 1,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      final items = await historyStore().read();
      if (items.length >= expectAtLeast) return items;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      '等 ${timeout.inSeconds}s 后 history.json 里仍然不到 $expectAtLeast 条',
    );
  }

  testWidgets('修完一张图 → history.json 落盘一条完整记录', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);

    final controller = container.read(imageEditControllerProvider.notifier);

    // 走真实链路：示例图 → 框选水印 → 调 Kotlin + OpenCV → 出结果
    await controller.loadSample();
    expect(controller.state.source, isNotNull, reason: '示例图应当加载成功');

    // 右下角那行「© THE COZY CORNER CAFE」，位置与 image_pipeline_test 一致
    controller.setDraft(
      const MaskDraft(rect: Rect.fromLTRB(0.855, 0.978, 0.998, 0.997)),
    );
    await controller.run();

    expect(controller.state.error, isNull, reason: '修复不该报错');
    expect(controller.state.resultPath, isNotNull, reason: '修复应当产出文件');

    final items = await waitForHistory();
    expect(items, hasLength(1));

    final item = items.first;
    expect(item.kind, HistoryKind.image);
    expect(item.status, TaskStatus.succeeded);
    expect(item.title, 'cafe.jpg', reason: '标题应当是原始文件名');
    expect(item.metaLabel, contains('1200'), reason: '元信息应当是真实尺寸');
    expect(item.createdAt, greaterThan(0), reason: '排序依据不能是 0');
    expect(item.timeLabel, isNotEmpty);

    // 缩略图：路径指向真实文件，且真能解码、真被压过
    expect(item.thumbPath, isNotNull, reason: '记录要带缩略图路径');
    final thumbFile = File(item.thumbPath!);
    expect(thumbFile.existsSync(), isTrue, reason: '缩略图文件必须真的存在');

    final codec = await ui.instantiateImageCodec(await thumbFile.readAsBytes());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    expect(image.width, lessThanOrEqualTo(kThumbnailMaxWidth));
    expect(image.height, greaterThan(0));
    debugPrint(
      'ITEST_PERSIST thumb=${image.width}x${image.height} '
      'bytes=${thumbFile.lengthSync()}',
    );
    image.dispose();
    codec.dispose();

    // ≈ 进程重启：换一个全新 store 实例，从磁盘读回
    final reopened = await FileHistoryStore(directory: () async => tmp).read();
    expect(reopened, hasLength(1));
    expect(reopened.first.id, item.id);
    expect(reopened.first.thumbPath, item.thumbPath);
  });

  testWidgets('清空历史 → history.json 清空、缩略图也删掉', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);

    final controller = container.read(imageEditControllerProvider.notifier);
    await controller.loadSample();
    controller.setDraft(
      const MaskDraft(rect: Rect.fromLTRB(0.855, 0.978, 0.998, 0.997)),
    );
    await controller.run();

    final items = await waitForHistory();
    final thumbPath = items.first.thumbPath;
    expect(thumbPath, isNotNull);
    expect(File(thumbPath!).existsSync(), isTrue);

    await container.read(historyItemsProvider.notifier).clear();

    expect(await historyStore().read(), isEmpty, reason: '磁盘上也要清空');

    // clearAll 走 `await for (dir.list())`，真实 IO 需要一点时间
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 5)) {
      if (!File(thumbPath).existsSync()) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      File(thumbPath).existsSync(),
      isFalse,
      reason: '记录删了、图还在，就是没人引用的孤儿',
    );
    debugPrint('ITEST_CLEAR ok 用时 ${watch.elapsedMilliseconds}ms');
  });

  testWidgets('主题写入后换实例读回（≈冷启动），没写之前是 null', (tester) async {
    ThemeModeStore store() => FileThemeModeStore(directory: () async => tmp);

    // 首次安装：没写过 → null，由 bootstrap 回落 system
    expect(await store().read(), isNull);

    await store().write(ThemeMode.dark);
    expect(await store().read(), ThemeMode.dark, reason: '换实例也要读得到');

    // 再改一次，确认覆盖而不是追加
    await store().write(ThemeMode.light);
    expect(await store().read(), ThemeMode.light);

    final file = File('${tmp.path}${Platform.pathSeparator}'
        '${FileThemeModeStore.fileName}');
    expect(file.existsSync(), isTrue);
    debugPrint('ITEST_THEME 落盘内容=${file.readAsStringSync().trim()}');
  });

  testWidgets('视频保存进相册（MediaStore.Video，不是 Pictures 图片库）', (tester) async {
    final data = await rootBundle.load('assets/samples/sample.mp4');
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final source = File('${dir.path}/itest_save_$stamp.mp4');
    await source.writeAsBytes(data.buffer.asUint8List(), flush: true);

    final uri = await const GallerySaver().saveVideo(
      sourcePath: source.path,
      displayName: 'itest_save_$stamp.mp4',
    );
    debugPrint('ITEST_VIDEO_SAVED uri=$uri');

    expect(uri, startsWith('content://media/'), reason: '应当返回 MediaStore URI');
    expect(uri, contains('video'), reason: '必须落在视频库，不能混进图片库');
  });
}
