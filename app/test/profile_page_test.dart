import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/app_info.dart';
import 'package:watermark_remover/core/storage/app_cache.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/profile/presentation/profile_page.dart';

/// 「我的」页。
///
/// 这一页之前的两个数字都是写死的（「已完成 15 项 · 26.8 MB」「清理缓存 128 MB」），
/// 点下去只弹一句「暂未开放」—— 界面在撒谎。测试盯的就是「数字来自真实状态、
/// 点了真的会做事」。
///
/// 真文件系统的清理逻辑在 `app_cache_test.dart`；这里用 `MemoryCacheStore`
/// 只验证「页面把 store 的结果正确呈现、并把点击转成一次 clear()」。
void main() {
  HistoryItem done(String id) => HistoryItem(
    id: id,
    title: '$id.jpg',
    kind: HistoryKind.image,
    status: TaskStatus.succeeded,
    timeLabel: '今天 10:00',
    metaLabel: '1200 × 896',
    createdAt: 0,
  );

  Future<void> pumpProfile(
    WidgetTester tester, {
    required MemoryCacheStore cache,
    List<HistoryItem> history = const <HistoryItem>[],
    AppInfo appInfo = const AppInfo(version: '0.1.0', buildNumber: '1'),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appCacheStoreProvider.overrideWithValue(cache),
          initialHistoryProvider.overrideWithValue(history),
          // 版本由 bootstrap 注入（源头是 pubspec 的 version:），测试里直接给定，
          // 这样「界面读 provider 还是写死」是可证的。
          initialAppInfoProvider.overrideWithValue(appInfo),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ProfilePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 视口扫描：「我的」页有统计数字与缓存行，窄屏最容易挤。
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

        await pumpProfile(
          tester,
          cache: MemoryCacheStore(),
          history: <HistoryItem>[done('a'), done('b')],
        );

        expect(
          tester.takeException(),
          isNull,
          reason: '${size.width.toInt()}×${size.height.toInt()} 下布局溢出了',
        );
      });
    }
  });

  testWidgets('概览数字来自真实历史，没有记录时不编数字', (tester) async {
    await pumpProfile(tester, cache: MemoryCacheStore());

    expect(find.text('还没有处理记录'), findsOneWidget);
    expect(find.textContaining('已完成 15 项'), findsNothing);
  });

  testWidgets('概览计数随历史条数变化', (tester) async {
    await pumpProfile(
      tester,
      cache: MemoryCacheStore(),
      history: [done('a'), done('b')],
    );

    expect(find.text('已完成 2 项 · 共 2 条记录'), findsOneWidget);
  });

  testWidgets('缓存体积显示真实值，不是写死的 128 MB', (tester) async {
    await pumpProfile(
      tester,
      cache: MemoryCacheStore(
        snapshot: const CacheSnapshot(removableBytes: 3 * 1024 * 1024),
      ),
    );

    expect(find.text('3.0 MB'), findsOneWidget);
    expect(find.text('128 MB'), findsNothing);
  });

  testWidgets('没有缓存时显示「无」', (tester) async {
    await pumpProfile(tester, cache: MemoryCacheStore());

    expect(find.text('无'), findsOneWidget);
  });

  testWidgets('点「清理缓存」真的调用 store，并把释放量说出来', (tester) async {
    final cache = MemoryCacheStore(
      snapshot: const CacheSnapshot(removableBytes: 2 * 1024 * 1024),
      report: const CacheClearReport(freedBytes: 2 * 1024 * 1024),
    );
    await pumpProfile(tester, cache: cache);

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();

    expect(cache.clearCalls, 1);
    expect(find.textContaining('已释放 2.0 MB'), findsOneWidget);
    // 清完之后体积要刷新，否则数字一直停在旧值
    expect(find.text('无'), findsOneWidget);
  });

  testWidgets('成果被保住时，提示里要说出来（不然用户以为没清干净）', (tester) async {
    final cache = MemoryCacheStore(
      snapshot: const CacheSnapshot(
        removableBytes: 1024 * 1024,
        keptBytes: 900 * 1024,
        keptCount: 1,
      ),
      report: const CacheClearReport(
        freedBytes: 1024 * 1024,
        keptBytes: 900 * 1024,
        keptCount: 1,
      ),
    );
    await pumpProfile(tester, cache: cache);

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('保留 1 个未导出的成果'), findsOneWidget);
  });

  testWidgets('删不掉的文件要如实说，不能假装全清干净了', (tester) async {
    final cache = MemoryCacheStore(
      snapshot: const CacheSnapshot(removableBytes: 1024),
      report: const CacheClearReport(freedBytes: 0, failedCount: 2),
    );
    await pumpProfile(tester, cache: cache);

    await tester.tap(find.text('清理缓存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 个文件被占用'), findsOneWidget);
  });

  testWidgets('没实现的「默认修复质量」不该占位', (tester) async {
    await pumpProfile(tester, cache: MemoryCacheStore());

    expect(find.text('默认修复质量'), findsNothing);
    expect(find.text('高清'), findsNothing);
  });

  testWidgets('「关于」点了要有反应（原来是空函数）', (tester) async {
    await pumpProfile(tester, cache: MemoryCacheStore());

    await tester.tap(find.text('关于水印工坊'));
    await tester.pumpAndSettle();

    expect(find.text('水印工坊 v0.1.0'), findsOneWidget);
    expect(find.textContaining('构建号 1'), findsOneWidget);
  });

  testWidgets('版本号真的来自 provider，不是写死的 v0.1.0', (tester) async {
    await pumpProfile(
      tester,
      cache: MemoryCacheStore(),
      appInfo: const AppInfo(version: '2.3.4', buildNumber: '77'),
    );

    // 三处引用都得跟着变：设置行、底部说明、关于弹窗标题
    expect(find.text('v2.3.4'), findsOneWidget);
    expect(find.textContaining('水印工坊 v2.3.4 · 本地优先'), findsOneWidget);
    expect(find.textContaining('v0.1.0'), findsNothing);

    await tester.tap(find.text('关于水印工坊'));
    await tester.pumpAndSettle();
    expect(find.text('水印工坊 v2.3.4'), findsOneWidget);
  });
}
