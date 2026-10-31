import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/app/app.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';

/// 冒烟测试：把「路由 + 状态管理 + 主题」三条集成链路各走一遍。
///
/// 这不是业务测试，它的价值在于：任何一次依赖升级把 go_router 的
/// StatefulShellRoute 或 Riverpod 的 ProviderScope 改坏，这里会立刻红。
///
/// 历史数据是**真实持久化**的（默认空），所以这里显式塞假数据 + 内存 store ——
/// 断言的是「列表 / 筛选 / 详情」这条链路，不是数据来源。
void main() {
  testWidgets('启动 → 切 Tab → 筛选 → 进详情 → 换深色主题', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialHistoryProvider.overrideWithValue(demoHistory),
          historyStoreProvider.overrideWithValue(MemoryHistoryStore()),
        ],
        child: const WatermarkApp(),
      ),
    );
    await tester.pumpAndSettle();

    // ── 首页 ──
    expect(find.text('水印工坊'), findsOneWidget);
    expect(find.text('图片去水印'), findsOneWidget);
    expect(find.text('视频去水印'), findsOneWidget);

    // ── 切到历史 Tab（StatefulShellRoute 生效）──
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('全部 6'), findsOneWidget);

    // ── 筛选「视频」：派生 provider 重算 ──
    await tester.tap(find.text('视频 2'));
    await tester.pumpAndSettle();
    expect(find.text('咖啡馆拉花.mp4'), findsOneWidget);
    expect(find.text('湖边晨雾.jpg'), findsNothing);

    // ── 带路由参数进详情页 ──
    await tester.tap(find.text('咖啡馆拉花.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('处理详情'), findsOneWidget);
    expect(find.text('轨迹 900 帧 · 3 个关键帧'), findsOneWidget);

    // 返回后列表状态仍在。
    // 注意：这里不能用 tester.pageBack() —— 它按 tooltip 'Back' 找按钮，
    // 而本项目 locale 是 zh_CN，tooltip 是「返回」，直接找 BackButton 更稳。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('咖啡馆拉花.mp4'), findsOneWidget);

    // ── 我的 → 切深色：验证 ThemeMode 由 Riverpod 驱动 ──
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });
}
