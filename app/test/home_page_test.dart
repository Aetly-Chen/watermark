import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/app/app.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';

/// 首页。
///
/// 这一屏此前只在冒烟测试里被顺带看过（标题在、两个入口在、Tab 能切），
/// 但它自己有三件容易悄悄坏掉的事：
///
/// 1. **`最近处理` 只取 2 条** —— `take(2)`。哪天有人「顺手」改成全部，
///    首页会变成第二个历史页，而且长得像正常。
/// 2. **副标题是承诺**。原来视频写 `MP4 · MOV · AVI`，而 `MediaExtractor`
///    根本没有 AVI 解析器。这一条断言是**防回归**用的：
///    以后谁再「补全格式」，测试会当场红。
/// 3. **入口卡真的能进**。`_EntryCard` 的 `onTap` 传的是 `VoidCallback`，
///    给个空函数也能编译、也能点 —— 点了没反应，和按钮失效那个事故同款。
void main() {
  HistoryItem item(String id) => HistoryItem(
    id: id,
    title: '$id.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '今天 10:00',
    metaLabel: '1200 × 896 · 1.2 MB',
    createdAt: 0,
  );

  /// 首页是 shell 里的第一个分支，直接起整个 App 比手搓 router 更接近真实。
  Future<void> pumpHome(
    WidgetTester tester, {
    List<HistoryItem> initial = const <HistoryItem>[],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialHistoryProvider.overrideWithValue(initial),
          historyStoreProvider.overrideWithValue(MemoryHistoryStore()),
        ],
        child: const WatermarkApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有记录：最近处理要说「还没有」，不能只剩一个标题', (tester) async {
    await pumpHome(tester);

    expect(find.text('最近处理'), findsOneWidget);
    expect(find.textContaining('还没有处理记录'), findsOneWidget);
  });

  testWidgets('最近处理最多 2 条：滚到底也不出第 3 条', (tester) async {
    // 顺序即 provider 给的顺序（文件里就是新记录在前），这里直接控死。
    await pumpHome(tester, initial: [item('a'), item('b'), item('c')]);

    expect(find.text('a.jpg'), findsOneWidget, reason: '最新那条要在');
    expect(find.text('b.jpg'), findsOneWidget, reason: '第 2 条也要在');

    // ⚠ 不滚就断言 `c.jpg` 不存在是**假通过**：ListView 懒加载，
    // 看不见的东西本来就没被构建，`take(2)` 写没写都过。
    // 必须真的滚到底，让「如果它存在就一定会被构建」这个前提成立。
    await tester.scrollUntilVisible(
      find.text('全部记录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('c.jpg'),
      findsNothing,
      reason: '首页是概览不是列表，第 3 条起归历史页',
    );
  });

  testWidgets('入口卡的副标题只写真能解的格式（钉住 AVI 那个假承诺）', (tester) async {
    await pumpHome(tester);

    expect(find.text('JPG · PNG · WEBP · HEIC'), findsOneWidget);
    expect(
      find.text('MP4 · MOV · MKV · 逐帧修复'),
      findsOneWidget,
      reason: 'MediaExtractor 没有 AVI 解析器，写了就是选完直接报错',
    );
    expect(find.textContaining('AVI'), findsNothing);
    expect(find.textContaining('RMVB'), findsNothing);
  });

  testWidgets('点「图片去水印」真的进图片页', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.text('图片去水印'));
    await tester.pumpAndSettle();

    // 用图片页独有的入口按钮判断 —— 两个页面的 AppBar 标题和首页卡片**同名**，
    // 拿 `find.text('图片去水印')` 断言会同时命中下面那层路由。
    expect(find.text('用示例图'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
  });

  testWidgets('点「视频去水印」真的进视频页', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.text('视频去水印'));
    await tester.pumpAndSettle();

    expect(find.text('用示例视频'), findsOneWidget);
    expect(find.text('用示例图'), findsNothing, reason: '别串到图片页');
  });

  testWidgets('「全部记录」切到历史 Tab', (tester) async {
    await pumpHome(tester, initial: [item('a')]);

    await tester.scrollUntilVisible(
      find.text('全部记录'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();

    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('全部 1'), findsOneWidget, reason: '数字要跟着真实记录走');
  });

  testWidgets('点最近记录进详情页', (tester) async {
    await pumpHome(tester, initial: [item('a')]);

    await tester.tap(find.text('a.jpg'));
    await tester.pumpAndSettle();

    expect(find.text('处理详情'), findsOneWidget);
  });
}
