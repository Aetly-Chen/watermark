import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_format.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/presentation/history_detail_page.dart';

/// 历史详情页。
///
/// 这一页原来有三处「看着正常其实是坏的」：
///   1. 顶部 200px 的预览框里永远只有一个图标 —— 像图加载失败；
///   2. 「类型」显示 `item.kind.name`，中文界面里冒出英文 `image` / `video`；
///   3. 「重新处理」只是跳到空白编辑页，不带任何素材，名字却在承诺「处理原来那张」。
void main() {
  // 1×1 透明 PNG，能真的解码成功。
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  HistoryItem record({
    HistoryKind kind = HistoryKind.image,
    String? thumbPath,
    int createdAt = 1,
  }) => HistoryItem(
    id: 'r1',
    title: '湖边晨雾.jpg',
    kind: kind,
    status: TaskStatus.succeeded,
    timeLabel: '今天 14:20',
    metaLabel: '1200 × 896 · 1.2 MB',
    detail: '框选修复 · 用时 1.2 s',
    createdAt: createdAt,
    thumbPath: thumbPath,
  );

  Future<void> pumpDetail(WidgetTester tester, HistoryItem item) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [initialHistoryProvider.overrideWithValue([item])],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const HistoryDetailPage(taskId: 'r1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('类型显示中文，不是 image / video', (tester) async {
    await pumpDetail(tester, record(kind: HistoryKind.video));

    expect(find.text('视频'), findsOneWidget);
    expect(find.text('video'), findsNothing);
    expect(find.text('image'), findsNothing);
  });

  testWidgets('有缩略图：显示图片而不是占位图标', (tester) async {
    final dir = Directory.systemTemp.createTempSync('wm_detail_thumb');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}/r1.png')..writeAsBytesSync(png);

    await pumpDetail(tester, record(thumbPath: file.path));

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('没有缩略图：退回图标（老记录 / 生成失败都走这条）', (tester) async {
    await pumpDetail(tester, record());

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsWidgets);
  });

  // ⚠ 默认视口只有 800×600，16:9 的预览区自己就吃掉 432px，
  // 说明文字和按钮都在屏幕外 —— ListView 懒加载不会构建它们。
  // 不滚就断言，会得到「文案没改」的假结论（我第一次就是这么被误导的）。
  //
  // 而且**一棵树只滚一次**：同一用例里第二次 pumpWidget 时 Scrollable 的
  // Element 会被复用，第二次 scrollUntilVisible 直接 `Bad state: No element`。
  // 所以下面两个方向各自开一个用例。
  Future<void> revealBottom(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('图片记录的按钮文案是「再处理一张图片」', (tester) async {
    await pumpDetail(tester, record(kind: HistoryKind.image));
    await revealBottom(tester, find.text('再处理一张图片'));

    expect(find.text('再处理一张图片'), findsOneWidget);
    // 旧文案在承诺「处理原来那张」，而历史并不存素材 —— 它不该再出现
    expect(find.text('重新处理'), findsNothing);
  });

  testWidgets('视频记录的按钮文案是「再处理一个视频」', (tester) async {
    await pumpDetail(tester, record(kind: HistoryKind.video));
    await revealBottom(tester, find.text('再处理一个视频'));

    expect(find.text('再处理一个视频'), findsOneWidget);
  });

  testWidgets('说明历史不保留素材，避免用户以为能找回原图', (tester) async {
    await pumpDetail(tester, record());
    await revealBottom(tester, find.textContaining('历史只保留处理记录'));

    expect(find.textContaining('历史只保留处理记录'), findsOneWidget);
  });

  // 「完成时间」那一行在预览图下方，800×600 视口里屏外 —— 不滚断言
  // `findsNothing` 会因为「压根没构建」而假通过。
  testWidgets('完成时间按 createdAt 现算，不用落盘时冻住的字符串', (tester) async {
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
    await pumpDetail(
      tester,
      record(createdAt: twoDaysAgo.millisecondsSinceEpoch),
    );
    await revealBottom(tester, find.text('完成时间'));

    expect(
      find.textContaining('今天'),
      findsNothing,
      reason: '两天前还显示「今天」，说明读的是落盘字符串',
    );
    expect(find.text(formatHistoryTime(twoDaysAgo)), findsOneWidget);
  });
}
