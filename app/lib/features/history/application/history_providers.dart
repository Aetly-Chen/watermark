import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/media/thumbnail_store.dart';
import '../domain/history_item.dart';
import '../infrastructure/history_store.dart';

part 'history_providers.g.dart';

/// 启动时从磁盘读回的历史（见 `bootstrap.dart`）。默认空 —— 新装的 App 本来就没有记录。
final Provider<List<HistoryItem>> initialHistoryProvider =
    Provider<List<HistoryItem>>((ref) => const <HistoryItem>[]);

/// 存储实现。测试里换成 `MemoryHistoryStore`。
final Provider<HistoryStore> historyStoreProvider = Provider<HistoryStore>(
  (ref) => const FileHistoryStore(),
);

/// 假数据，只在测试和截图里用 —— **不要**再让它当运行时的默认值。
/// 之前历史页显示的就是这份写死的 6 条，看起来像功能做好了，其实是假的。
const List<HistoryItem> demoHistory = <HistoryItem>[
  HistoryItem(
    id: 'h1',
    title: '湖边晨雾.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '今天 14:20',
    metaLabel: '1200 × 896 · 1.2 MB',
    detail: '矩形选区 · 修复半径 6 px',
    createdAt: 1759900000000,
  ),
  HistoryItem(
    id: 'h2',
    title: '咖啡馆拉花.mp4',
    kind: HistoryKind.video,
    status: TaskStatus.succeeded,
    timeLabel: '今天 13:10',
    metaLabel: '00:24 · 8.4 MB',
    detail: '轨迹 900 帧 · 3 个关键帧',
    createdAt: 1759896000000,
  ),
  HistoryItem(
    id: 'h3',
    title: '街角立面.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.cancelled,
    timeLabel: '今天 11:32',
    metaLabel: '1200 × 896 · 900 KB',
    detail: '用户取消',
    createdAt: 1759890000000,
  ),
  HistoryItem(
    id: 'h4',
    title: '山脊倒影.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '昨天 17:40',
    metaLabel: '1200 × 896 · 2.1 MB',
    detail: '画笔涂抹 · 修复半径 8 px',
    createdAt: 1759820000000,
  ),
  HistoryItem(
    id: 'h5',
    title: '拿铁特写.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '昨天 16:05',
    metaLabel: '1200 × 896 · 1.7 MB',
    detail: '矩形选区 · 修复半径 6 px',
    createdAt: 1759815000000,
  ),
  HistoryItem(
    id: 'h6',
    title: '街区立面.mp4',
    kind: HistoryKind.video,
    status: TaskStatus.succeeded,
    timeLabel: '10-15 09:12',
    metaLabel: '00:18 · 6.2 MB',
    detail: '静态水印 · 单 Mask 全片',
    createdAt: 1759000000000,
  ),
];

/// 历史记录（真实数据）。上层只要是 `List<HistoryItem>` 的消费者，一行都不用改。
@Riverpod(keepAlive: true)
class HistoryItems extends _$HistoryItems {
  /// 上限：本地小工具不需要无限历史，超出的丢最旧一条，文件不会越长越大。
  static const int maxEntries = 50;

  @override
  List<HistoryItem> build() => ref.read(initialHistoryProvider);

  /// 新记录插到最前并落盘。写盘失败不影响内存里的列表（用户仍能在本次会话看到）。
  Future<void> add(HistoryItem item) async {
    // ⚠ 必须先 materialize：下面会把 `state` 换掉，惰性 iterable 这时会读到新值，
    // 于是「被覆盖的旧记录」一条都取不到，缩略图静默漏删。
    // 取快照再遍历。惰性 iterable 在当前代码里其实也安全（`state` 是重新赋值，
    // 旧 list 不会被就地修改 —— 变异验证过：去掉 toList 用例照样绿），
    // 但写死快照就不必每次重新论证这一点。
    final replaced = state
        .where((existing) => existing.id == item.id)
        .toList(growable: false);

    final next = <HistoryItem>[
      item,
      ...state.where((existing) => existing.id != item.id),
    ];

    // 超限时被挤出去的记录，它们的缩略图必须跟着删。
    final dropped = next.length > maxEntries
        ? next.sublist(maxEntries)
        : const <HistoryItem>[];

    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    state = List<HistoryItem>.unmodifiable(next);
    await ref.read(historyStoreProvider).write(state);

    // 记录消失有**三条**路径：清空记录、超 50 条挤掉、同 id 覆盖。
    // 三条都得把缩略图一起删，否则 `thumbs/` 只增不减 —— 而且用户在
    // 「清理缓存」里也看不到它们（缩略图在应用支持目录，不在缓存目录）。
    final stale = <String>[];
    for (final old in <HistoryItem>[...replaced, ...dropped]) {
      final thumb = old.thumbPath;
      // 老记录（缩略图功能之前产生的）没有这个字段，别拿 null 去调删。
      if (thumb == null || thumb.isEmpty) continue;
      // 新旧指向同一个文件时不能删 —— 那不是孤儿，删了就是把还在用的图删掉。
      if (thumb == item.thumbPath) continue;
      stale.add(thumb);
    }

    if (stale.isNotEmpty) {
      // 不 await：删不掉孤儿图不该让「历史写成功了」变成失败。
      final store = ref.read(thumbnailStoreProvider);
      for (final path in stale) {
        unawaited(store.remove(path));
      }
    }
  }

  Future<void> clear() async {
    if (state.isEmpty) return;
    final hadThumbs = state.any((item) => item.thumbPath != null);
    state = const <HistoryItem>[];
    await ref.read(historyStoreProvider).write(state);
    // 记录没了，缩略图就成了没人引用的孤儿文件 —— 一起清掉，
    // 否则「清空记录」之后磁盘占用一点都不降（用户在「清理缓存」里也看不到它们，
    // 因为缩略图在应用支持目录，不在缓存目录）。
    if (hadThumbs) {
      await ref.read(thumbnailStoreProvider).clearAll();
    }
  }
}

/// 当前筛选（null = 全部）。用 Notifier 而不是 UI 里的 local state，
/// 是为了让「历史页筛选」将来能被深链或通知直接指定。
@Riverpod(keepAlive: true)
class HistoryFilter extends _$HistoryFilter {
  @override
  HistoryKind? build() => null;

  void setKind(HistoryKind? kind) {
    if (state == kind) return;
    state = kind;
  }
}

/// 派生状态：筛选后的列表。数据或筛选一变就重算，UI 只 watch 这一个。
@riverpod
List<HistoryItem> visibleHistory(Ref ref) {
  final kind = ref.watch(historyFilterProvider);
  final items = ref.watch(historyItemsProvider);
  if (kind == null) return items;
  return items.where((item) => item.kind == kind).toList(growable: false);
}

/// 按 id 取单条（详情页用）。找不到返回 null，由页面决定怎么展示。
@riverpod
HistoryItem? historyItemById(Ref ref, String id) {
  for (final item in ref.watch(historyItemsProvider)) {
    if (item.id == id) return item;
  }
  return null;
}
