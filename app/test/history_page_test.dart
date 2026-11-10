import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/thumbnail_store.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_format.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';
import 'package:watermark_remover/features/history/presentation/history_page.dart';

/// 历史页。
///
/// 右上角那个按钮原来是假的（弹「批量管理待接入本地数据库后开放」，而数据库早就接了）。
/// 现在它清空真实记录，于是这一组测试重点盯**危险操作的护栏**：
/// 二次确认必须弹、点取消必须什么都不发生、0 条时不许弹确认框。
void main() {
  HistoryItem item(String id, {String? thumbPath}) => HistoryItem(
    id: id,
    title: '$id.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '今天 10:00',
    metaLabel: '1200 × 896 · 1.2 MB',
    createdAt: 0,
    thumbPath: thumbPath,
  );

  Future<void> pumpHistory(
    WidgetTester tester, {
    required List<HistoryItem> initial,
    required MemoryHistoryStore store,
    ThumbnailStore? thumbnails,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialHistoryProvider.overrideWithValue(initial),
          historyStoreProvider.overrideWithValue(store),
          if (thumbnails != null)
            thumbnailStoreProvider.overrideWithValue(thumbnails),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const HistoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 视口扫描：有记录时，列表项 + 筛选行在窄屏 / 横屏装不装得下。
  group('视口不溢出', () {
    const sizes = <Size>[
      Size(320, 568),
      Size(360, 640),
      Size(412, 915),
      Size(780, 360),
    ];

    for (final size in sizes) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpHistory(
          tester,
          initial: <HistoryItem>[item('a'), item('b'), item('c')],
          store: MemoryHistoryStore(),
        );

        expect(
          tester.takeException(),
          isNull,
          reason: '${size.width.toInt()}×${size.height.toInt()} 下布局溢出了',
        );
      });
    }
  });

  testWidgets('没有记录：空态说清楚去哪里产生记录', (tester) async {
    await pumpHistory(
      tester,
      initial: const <HistoryItem>[],
      store: MemoryHistoryStore(),
    );

    expect(find.text('还没有处理记录'), findsOneWidget);
    expect(find.textContaining('修完的图片和视频会出现在这里'), findsOneWidget);
  });

  testWidgets('有记录：标题与筛选计数都来自真实数据', (tester) async {
    await pumpHistory(
      tester,
      initial: [item('a'), item('b')],
      store: MemoryHistoryStore(),
    );

    expect(find.text('全部 2'), findsOneWidget);
    expect(find.text('图片 2'), findsOneWidget);
    expect(find.text('视频 0'), findsOneWidget);
    expect(find.text('a.jpg'), findsOneWidget);
  });

  testWidgets('清空要二次确认：点「取消」什么都不发生', (tester) async {
    final store = MemoryHistoryStore([item('a'), item('b')]);
    await pumpHistory(tester, initial: [item('a'), item('b')], store: store);

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();

    expect(find.text('清空 2 条记录？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('a.jpg'), findsOneWidget);
    expect(store.writeCount, 0, reason: '点取消不该写盘');
  });

  testWidgets('确认后真的清空，并且只说清记录、不说删文件', (tester) async {
    final store = MemoryHistoryStore([item('a'), item('b')]);
    await pumpHistory(tester, initial: [item('a'), item('b')], store: store);

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('还没有处理记录'), findsOneWidget);
    expect(find.text('全部 0'), findsOneWidget);
    expect(store.items, isEmpty);
    expect(store.writeCount, 1);
    expect(find.textContaining('相册里的成品未受影响'), findsOneWidget);
  });

  testWidgets('0 条时点清空：直接提示，不弹确认框', (tester) async {
    await pumpHistory(
      tester,
      initial: const <HistoryItem>[],
      store: MemoryHistoryStore(),
    );

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();

    expect(find.text('还没有记录可清空'), findsOneWidget);
    expect(find.textContaining('条记录？'), findsNothing);
  });

  testWidgets('确认后通知缩略图一起清掉，不留孤儿文件', (tester) async {
    // 只断言「通知了」，不在这里断言文件真的没了：
    //   · 真实删除动作由 `thumbnail_test.dart` 的普通 test() 验证（那里是真实异步环境）；
    //   · testWidgets 跑在 FakeAsync 里，`clearAll()` 内部的 `await for (dir.list())`
    //     不会被推进，硬断言文件消失会得到**假失败**（我上一版就卡在这儿）。
    // 这一条盯的是 clear() 有没有把 clearAll() 接上 —— 那才是会忘的地方。
    final withThumb = item('a', thumbPath: '/nowhere/a.png');
    final spy = _SpyThumbnailsStore();
    await pumpHistory(
      tester,
      initial: [withThumb],
      store: MemoryHistoryStore([withThumb]),
      thumbnails: spy,
    );

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(spy.clearCalls, 1, reason: '记录删了、图还在，就是没人引用的垃圾');
  });

  testWidgets('没有缩略图的记录：不去碰缩略图目录', (tester) async {
    final spy = _SpyThumbnailsStore();
    await pumpHistory(
      tester,
      initial: [item('a')],
      store: MemoryHistoryStore([item('a')]),
      thumbnails: spy,
    );

    await tester.tap(find.byTooltip('清空记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(spy.clearCalls, 0);
  });

  // 真机抓到的现场（2026-10-22）：8 条记录跨 10-20～10-22，**全部显示「今天」**。
  // 原因是 timeLabel 在写入时就冻成字符串，注释却说「隔天自然变成昨天」。
  // 这两条盯的是「界面真的按 createdAt 现算」，而不只是那个函数自己算得对 ——
  // 只改函数、界面仍读旧字段，函数层的用例照样绿。
  testWidgets('列表时间按 createdAt 现算，不显示落盘时冻住的字符串', (tester) async {
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
    final stale = HistoryItem(
      id: 'stale',
      title: 'stale.jpg',
      kind: HistoryKind.image,
      status: TaskStatus.succeeded,
      timeLabel: '今天 10:00', // 故意写成「今天」，模拟落盘时冻住的值
      metaLabel: '1200 × 896 · 1.2 MB',
      createdAt: twoDaysAgo.millisecondsSinceEpoch,
    );
    await pumpHistory(
      tester,
      initial: [stale],
      store: MemoryHistoryStore([stale]),
    );

    expect(
      find.textContaining('今天'),
      findsNothing,
      reason: '两天前的记录显示「今天」，就是把落盘字符串直接拿来显示了',
    );
    expect(
      find.text(formatHistoryTime(twoDaysAgo)),
      findsOneWidget,
      reason: '应该按 createdAt 现算出 MM-DD HH:mm',
    );
  });

  testWidgets('老记录没有时间戳：退回写入时的字符串，不显示 1970', (tester) async {
    // item() 的 createdAt 是 0，对应「加时间戳之前」落盘的记录。
    // 这些只能退回落盘字符串 —— 会永远停在写入那天，但总比显示 1970 强。
    await pumpHistory(
      tester,
      initial: [item('legacy')],
      store: MemoryHistoryStore([item('legacy')]),
    );

    expect(find.text('今天 10:00'), findsOneWidget);
    expect(find.textContaining('1970'), findsNothing);
  });
}

/// 只记「有没有被叫」，不碰文件系统。
class _SpyThumbnailsStore extends ThumbnailStore {
  _SpyThumbnailsStore();

  int clearCalls = 0;

  @override
  Future<void> clearAll() async {
    clearCalls++;
  }
}
