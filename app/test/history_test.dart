import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/format/sizes.dart';
import 'package:watermark_remover/core/media/thumbnail_store.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_format.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';

HistoryItem item(String id, {int at = 0, String? thumb}) => HistoryItem(
  id: id,
  title: '$id.jpg',
  kind: HistoryKind.image,
  status: TaskStatus.succeeded,
  timeLabel: '今天 10:00',
  metaLabel: '1200 × 896 · 1.2 MB',
  createdAt: at,
  thumbPath: thumb,
);

void main() {
  group('格式化', () {
    final now = DateTime(2026, 10, 20, 1, 5);

    test('今天 / 昨天 / 今年 / 跨年', () {
      expect(formatHistoryTime(DateTime(2026, 10, 20, 14, 20), now: now), '今天 14:20');
      expect(formatHistoryTime(DateTime(2026, 10, 19, 17, 40), now: now), '昨天 17:40');
      expect(formatHistoryTime(DateTime(2026, 10, 15, 9, 12), now: now), '10-15 09:12');
      expect(formatHistoryTime(DateTime(2025, 12, 3, 8, 0), now: now), '2025-12-03 08:00');
    });

    // 「今天」曾经是写死在记录里的字符串，隔天打开还是「今天」。
    // 2026-10-22 真机现场：8 条跨 3 天的记录全显示「今天」。
    test('展示时间按 createdAt 现算，不受落盘字符串影响', () {
      final ref = DateTime(2026, 10, 22, 16, 0);
      HistoryItem at(DateTime t) => HistoryItem(
        id: 'x',
        title: 'x.jpg',
        kind: HistoryKind.image,
        status: TaskStatus.succeeded,
        // 落盘时算的是「今天」，隔两天还是这串 —— 界面必须无视它
        timeLabel: '今天 19:08',
        metaLabel: '',
        createdAt: t.millisecondsSinceEpoch,
      );

      expect(at(DateTime(2026, 10, 22, 9, 30)).timeLabelAt(ref), '今天 09:30');
      expect(
        at(DateTime(2026, 10, 21, 19, 8)).timeLabelAt(ref),
        '昨天 19:08',
        reason: '昨天 19:08 距今 20.9 小时 —— 按小时数算会误判成今天',
      );
      expect(at(DateTime(2026, 10, 20, 19, 8)).timeLabelAt(ref), '10-20 19:08');
      expect(at(DateTime(2025, 12, 3, 8, 0)).timeLabelAt(ref), '2025-12-03 08:00');
    });

    test('createdAt 为 0 的老记录退回落盘字符串', () {
      const legacy = HistoryItem(
        id: 'old',
        title: 'old.jpg',
        kind: HistoryKind.image,
        status: TaskStatus.succeeded,
        timeLabel: '今天 19:08',
        metaLabel: '',
      );
      expect(legacy.timeLabelAt(DateTime(2026, 10, 22)), '今天 19:08');
    });

    test('体积按 1024 进位，保留一位小数', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(900 * 1024), '900 KB');
      expect(formatBytes((1.2 * 1024 * 1024).round()), '1.2 MB');
      // 别拿 2.05 GB 这种值当断言：double 里它是 2.0499…，四舍五入到 2.0 是对的
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
      expect(formatBytes(1536 * 1024 * 1024), '1.5 GB');
    });

    test('时长：不到一小时不显示小时位', () {
      expect(formatHistoryDuration(const Duration(seconds: 24)), '00:24');
      expect(formatHistoryDuration(const Duration(minutes: 5, seconds: 3)), '05:03');
      expect(
        formatHistoryDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });

  group('HistoryItem JSON', () {
    test('往返不丢字段', () {
      const original = HistoryItem(
        id: 'x1',
        title: '湖边.jpg',
        kind: HistoryKind.video,
        status: TaskStatus.cancelled,
        timeLabel: '昨天 09:00',
        metaLabel: '960 × 540 · 00:05',
        detail: '跟随画面',
        createdAt: 123,
        thumbPath: '/data/user/0/pkg/files/thumbs/x1.png',
      );
      final back = HistoryItem.fromJson(original.toJson());
      expect(back.id, original.id);
      expect(back.kind, HistoryKind.video);
      expect(back.status, TaskStatus.cancelled);
      expect(back.detail, '跟随画面');
      expect(back.createdAt, 123);
      expect(back.thumbPath, original.thumbPath);
    });

    test('老记录没有 thumbPath 字段也能读（向后兼容）', () {
      final back = HistoryItem.fromJson(<String, Object?>{
        'id': 'x3',
        'title': '旧记录.jpg',
        'kind': 'image',
        'status': 'succeeded',
      });
      expect(back.thumbPath, isNull);
      expect(back.title, '旧记录.jpg');
    });

    test('陌生枚举值回落默认，不抛异常', () {
      final back = HistoryItem.fromJson(<String, Object?>{
        'id': 'x2',
        'kind': 'gif',
        'status': '???',
      });
      expect(back.kind, HistoryKind.image);
      expect(back.status, TaskStatus.succeeded);
      expect(back.title, '未命名');
    });
  });

  group('FileHistoryStore', () {
    late Directory dir;
    late FileHistoryStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wm_history_');
      store = FileHistoryStore(directory: () async => dir);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('没有文件时返回空列表', () async {
      expect(await store.read(), isEmpty);
    });

    test('写进去再读回来，顺序与字段都保持', () async {
      await store.write(<HistoryItem>[item('a', at: 2), item('b', at: 1)]);
      final back = await store.read();
      expect(back.map((e) => e.id).toList(), <String>['a', 'b']);
      expect(back.first.metaLabel, '1200 × 896 · 1.2 MB');
    });

    test('文件被写坏时返回空列表，不抛', () async {
      await File(
        '${dir.path}${Platform.pathSeparator}${FileHistoryStore.fileName}',
      ).writeAsString('{not json');
      expect(await store.read(), isEmpty);
    });
  });

  group('HistoryItems', () {
    ProviderContainer make(MemoryHistoryStore store, List<HistoryItem> initial) {
      final c = ProviderContainer(
        overrides: [
          initialHistoryProvider.overrideWithValue(initial),
          historyStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('启动值来自 initialHistoryProvider', () {
      final c = make(MemoryHistoryStore(), <HistoryItem>[item('a')]);
      expect(c.read(historyItemsProvider).single.id, 'a');
    });

    test('新记录插到最前并落盘', () async {
      final store = MemoryHistoryStore();
      final c = make(store, <HistoryItem>[item('old')]);
      await c.read(historyItemsProvider.notifier).add(item('new'));

      expect(
        c.read(historyItemsProvider).map((e) => e.id).toList(),
        <String>['new', 'old'],
      );
      expect(store.items.map((e) => e.id).toList(), <String>['new', 'old']);
    });

    test('同 id 覆盖而不是重复追加', () async {
      final store = MemoryHistoryStore();
      final c = make(store, <HistoryItem>[item('same')]);
      await c.read(historyItemsProvider.notifier).add(item('same'));
      expect(c.read(historyItemsProvider).length, 1);
    });

    test('超过上限时丢最旧的，文件里也只留上限条', () async {
      final store = MemoryHistoryStore();
      final c = make(store, const <HistoryItem>[]);
      for (var i = 0; i < HistoryItems.maxEntries + 3; i++) {
        await c.read(historyItemsProvider.notifier).add(item('i$i'));
      }
      expect(c.read(historyItemsProvider).length, HistoryItems.maxEntries);
      expect(store.items.length, HistoryItems.maxEntries);
      // 最新的在最前，最旧的三条被丢掉
      expect(c.read(historyItemsProvider).first.id, 'i${HistoryItems.maxEntries + 2}');
      expect(c.read(historyItemsProvider).any((e) => e.id == 'i0'), isFalse);
    });

    /// 只记「删了哪些」，不碰文件系统。
    ///
    /// 这条是被自己坑出来的：加了缩略图之后，`add()` 超限时只丢记录、不删文件，
    /// 于是 `thumbs/` 会永久留下孤儿图 —— 「清理缓存」还看不到它们
    /// （缩略图在应用支持目录，不在缓存目录）。
    test('超限被挤掉的记录，缩略图要一起删', () async {
      final store = MemoryHistoryStore();
      final thumbs = _SpyThumbnailStore();
      final c = ProviderContainer(
        overrides: [
          initialHistoryProvider.overrideWithValue(const <HistoryItem>[]),
          historyStoreProvider.overrideWithValue(store),
          thumbnailStoreProvider.overrideWithValue(thumbs),
        ],
      );
      addTearDown(c.dispose);

      // 正好塞满上限，每条都带缩略图
      for (var i = 0; i < HistoryItems.maxEntries; i++) {
        await c.read(historyItemsProvider.notifier).add(
          item('i$i', thumb: '/t/i$i.png'),
        );
      }
      expect(thumbs.removed, isEmpty, reason: '还没超限，不该删任何图');

      await c.read(historyItemsProvider.notifier).add(
        item('newest', thumb: '/t/newest.png'),
      );
      // remove 是 unawaited 的，给它一轮事件循环
      await Future<void>.delayed(Duration.zero);

      expect(
        thumbs.removed,
        <String?>['/t/i0.png'],
        reason: '只有被挤掉的最旧那条该删，新的和别人都不能动',
      );
    });

    test('被挤掉的记录没有缩略图时，不瞎删', () async {
      final store = MemoryHistoryStore();
      final thumbs = _SpyThumbnailStore();
      final c = ProviderContainer(
        overrides: [
          initialHistoryProvider.overrideWithValue(const <HistoryItem>[]),
          historyStoreProvider.overrideWithValue(store),
          thumbnailStoreProvider.overrideWithValue(thumbs),
        ],
      );
      addTearDown(c.dispose);

      for (var i = 0; i < HistoryItems.maxEntries; i++) {
        // 老记录（缩略图功能之前产生的）没有 thumbPath
        await c.read(historyItemsProvider.notifier).add(item('i$i'));
      }
      await c.read(historyItemsProvider.notifier).add(item('newest'));
      await Future<void>.delayed(Duration.zero);

      // remove(null) 本身是安全的空操作，这里断言「没被调用」更严格，
      // 防止将来有人在 remove 里加了额外副作用。
      expect(thumbs.removed, isEmpty);
    });

    /// 记录消失的**第三条**路径：同 id 覆盖。
    ///
    /// 前两条（清空 / 超限挤掉）都接过，这条一直漏着 —— 旧记录被顶出列表，
    /// 它指向的缩略图就永远没人引用了。
    test('同 id 覆盖时，旧记录的缩略图要一起删', () async {
      final store = MemoryHistoryStore();
      final thumbs = _SpyThumbnailStore();
      final c = ProviderContainer(
        overrides: [
          initialHistoryProvider.overrideWithValue(
            <HistoryItem>[item('same', thumb: '/t/old.png')],
          ),
          historyStoreProvider.overrideWithValue(store),
          thumbnailStoreProvider.overrideWithValue(thumbs),
        ],
      );
      addTearDown(c.dispose);

      await c.read(historyItemsProvider.notifier).add(
        item('same', thumb: '/t/new.png'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.read(historyItemsProvider).length, 1);
      expect(
        thumbs.removed,
        <String?>['/t/old.png'],
        reason: '只删被覆盖的旧图，新的那张还在列表里用着',
      );
    });

    test('同 id 覆盖且指向同一个缩略图文件时，不能删', () async {
      final store = MemoryHistoryStore();
      final thumbs = _SpyThumbnailStore();
      final c = ProviderContainer(
        overrides: [
          initialHistoryProvider.overrideWithValue(
            <HistoryItem>[item('same', thumb: '/t/same.png')],
          ),
          historyStoreProvider.overrideWithValue(store),
          thumbnailStoreProvider.overrideWithValue(thumbs),
        ],
      );
      addTearDown(c.dispose);

      await c.read(historyItemsProvider.notifier).add(
        item('same', thumb: '/t/same.png'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        thumbs.removed,
        isEmpty,
        reason: '路径相同说明旧记录没有独占这张图，删了就是把还在用的图删掉',
      );
    });
  });
}

class _SpyThumbnailStore extends ThumbnailStore {
  _SpyThumbnailStore();

  final List<String?> removed = <String?>[];

  @override
  Future<void> remove(String? path) async => removed.add(path);
}
