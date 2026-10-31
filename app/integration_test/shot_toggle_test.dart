// 只为截「跟随开关展开态」这一张图。
//
// 为什么不用 `adb shell input tap`：本机 adb server 每条命令重起，连点会丢事件；
// 更重要的是 tap 会落到前台 App 上 —— 2026-10-18 就是这么把用户正在看的阅读器翻页的。
// 这里让 Flutter 自己去点（tester.tap 走真实的 hit test 和手势识别），
// 然后**停在那个画面上 25 秒**，外部用 `adb exec-out screencap` 抓。
//
// 跑法（不要用 flutter drive，它会跑完就卸包）：
//   flutter build apk --debug --target=integration_test/shot_toggle_test.dart \
//     --target-platform android-arm64
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n cn.shuiyin.watermark_remover/.MainActivity
//   # 另开一个终端，每 2 秒截一张，脚本见 D:/dev/vt/shot_toggle.sh
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:watermark_remover/app/app.dart';

/// 举起画面并保持真实时间流逝，供外部截屏。
Future<void> _hold(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
    // 给原生侧一帧时间去合成 —— 否则 screencap 抓到的还是上一帧
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 120),
        ));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('跟随开关展开态：截图取证', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: WatermarkApp()));
    await tester.pumpAndSettle();

    // 首页 → 视频去水印
    await tester.tap(find.text('视频去水印'));
    await tester.pumpAndSettle();
    debugPrint('SHOT_STAGE 视频页已打开');

    // 空态 → 用示例视频（内置 1 MB 短片，不经过相册，不会弹权限框）
    final sampleBtn = find.text('用示例视频');
    expect(sampleBtn, findsOneWidget, reason: '视频页空态没有「用示例视频」按钮');
    await tester.tap(sampleBtn);
    await tester.pump();
    debugPrint('SHOT_STAGE 正在探测示例视频');

    // 探测要 MediaMetadataRetriever + extractFrame，最慢见过 1.5s；给足 8 秒
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(Switch).evaluate().isNotEmpty) break;
    }
    expect(find.byType(Switch), findsOneWidget, reason: '视频没加载出来，开关没出现');
    debugPrint('SHOT_STAGE 开关已出现（默认关）');

    // 打开 → 停在展开态
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue, reason: '开关没打开');
    debugPrint('SHOT_STAGE 开关已打开，停 25 秒供截图');

    await _hold(tester, 25);

    debugPrint('SHOT_DONE 截图窗口已关闭');
  });
}
