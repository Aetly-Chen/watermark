import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/app_info.dart';
import 'package:watermark_remover/core/storage/app_cache.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/core/theme/app_tokens.dart';
import 'package:watermark_remover/core/theme/theme_mode_controller.dart';
import 'package:watermark_remover/core/theme/theme_mode_store.dart';
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

  group('主题模式切换按钮样式与暖调交互', () {
    Future<void> pumpThemedProfile(
      WidgetTester tester, {
      required ThemeMode initialMode,
      Brightness platformBrightness = Brightness.light,
    }) async {
      tester.platformDispatcher.platformBrightnessTestValue = platformBrightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appCacheStoreProvider.overrideWithValue(MemoryCacheStore()),
            initialHistoryProvider.overrideWithValue(const <HistoryItem>[]),
            initialAppInfoProvider.overrideWithValue(
              const AppInfo(version: '0.1.0', buildNumber: '1'),
            ),
            initialThemeModeProvider.overrideWithValue(initialMode),
            themeModeStoreProvider.overrideWithValue(MemoryThemeModeStore()),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              final themeMode = ref.watch(themeModeControllerProvider);
              return MaterialApp(
                theme: AppTheme.light(),
                darkTheme: AppTheme.dark(),
                themeMode: themeMode,
                home: const ProfilePage(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    void expectThemeModeTabs(
      WidgetTester tester, {
      required ThemeMode selectedMode,
      required AppTokens expectedTokens,
      bool assertDarkerTrack = false,
    }) {
      // 外层凹槽底色应精确等于当前主题的 t.track
      final groove = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('theme-mode-system')),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final grooveBox = groove.decoration as BoxDecoration;
      expect(grooveBox.color, expectedTokens.track);

      if (assertDarkerTrack) {
        expect(
          expectedTokens.flame.computeLuminance(),
          greaterThan(expectedTokens.track.computeLuminance()),
          reason: '深色模式下选中态 flame 必须亮于凹槽 track',
        );
      }

      const entries = <(ThemeMode, String)>[
        (ThemeMode.system, 'theme-mode-system'),
        (ThemeMode.light, 'theme-mode-light'),
        (ThemeMode.dark, 'theme-mode-dark'),
      ];

      for (final (mode, keyName) in entries) {
        final tab = find.byKey(ValueKey(keyName));
        expect(tab, findsOneWidget);

        // 读取 AnimatedContainer 内部真实参与绘制的 DecoratedBox
        final decorated = tester.widget<DecoratedBox>(
          find
              .descendant(of: tab, matching: find.byType(DecoratedBox))
              .first,
        );
        final box = decorated.decoration as BoxDecoration;
        final inkWell = tester.widget<InkWell>(
          find.descendant(of: tab, matching: find.byType(InkWell)),
        );

        final isSelected = mode == selectedMode;
        if (isSelected) {
          expect(
            box.color,
            expectedTokens.flame,
            reason: '$keyName 选中态背景必须精确等于当前主题 AppTokens.flame',
          );
          expect(
            inkWell.hoverColor,
            expectedTokens.onFlame.withValues(alpha: 0.12),
          );
          expect(
            inkWell.splashColor,
            expectedTokens.onFlame.withValues(alpha: 0.16),
          );
          expect(
            inkWell.highlightColor,
            expectedTokens.onFlame.withValues(alpha: 0.08),
          );
        } else {
          expect(
            box.color,
            Colors.transparent,
            reason: '$keyName 未选中态背景必须保持透明',
          );
          expect(inkWell.hoverColor, expectedTokens.hoverTint);
          expect(
            inkWell.splashColor,
            expectedTokens.flame.withValues(alpha: 0.14),
          );
          expect(inkWell.highlightColor, expectedTokens.hoverTint);
        }
      }
    }

    testWidgets('浅色主题：选中「浅色」背景等于 light.flame，未选中透明且暖调悬停/水波纹一致', (
      tester,
    ) async {
      await pumpThemedProfile(tester, initialMode: ThemeMode.light);

      expect(
        Theme.of(tester.element(find.byType(ProfilePage))).brightness,
        Brightness.light,
      );
      expectThemeModeTabs(
        tester,
        selectedMode: ThemeMode.light,
        expectedTokens: AppTokens.light(),
      );
    });

    testWidgets('深色主题：选中「深色」背景等于 dark.flame（亮于凹槽），未选中透明且暖调悬停/水波纹一致', (
      tester,
    ) async {
      await pumpThemedProfile(tester, initialMode: ThemeMode.dark);

      expect(
        Theme.of(tester.element(find.byType(ProfilePage))).brightness,
        Brightness.dark,
      );
      expectThemeModeTabs(
        tester,
        selectedMode: ThemeMode.dark,
        expectedTokens: AppTokens.dark(),
        assertDarkerTrack: true,
      );
    });

    testWidgets('交互切换：跟随系统（深/浅）→ 深色 → 浅色，三键选中背景与暖调配置同步更新', (
      tester,
    ) async {
      await pumpThemedProfile(
        tester,
        initialMode: ThemeMode.system,
        platformBrightness: Brightness.dark,
      );

      // 初始为「跟随系统」且系统处于深色
      expectThemeModeTabs(
        tester,
        selectedMode: ThemeMode.system,
        expectedTokens: AppTokens.dark(),
        assertDarkerTrack: true,
      );

      // 点「深色」
      await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
      await tester.pumpAndSettle();
      expectThemeModeTabs(
        tester,
        selectedMode: ThemeMode.dark,
        expectedTokens: AppTokens.dark(),
        assertDarkerTrack: true,
      );

      // 点「浅色」：整树切回浅色令牌
      await tester.tap(find.byKey(const ValueKey('theme-mode-light')));
      await tester.pumpAndSettle();
      expectThemeModeTabs(
        tester,
        selectedMode: ThemeMode.light,
        expectedTokens: AppTokens.light(),
      );
    });
  });
}
