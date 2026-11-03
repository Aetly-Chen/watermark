import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/widgets/editor_canvas_layout.dart';

/// 画布 + 控制面板在「高」和「矮」两种视口下的行为。
///
/// 回归的是一条真机缺陷：1080×2340 转横屏后视频页画布只剩约 31dp（93px），
/// 封面帧缩成拇指大、标签压在画面上，框选水印根本没法用。
void main() {
  const canvasKey = ValueKey('test-canvas');
  const controlsKey = ValueKey('test-controls');

  /// 注意：必须用 setSurfaceSize 改测试画布尺寸。
  /// 默认画布是 800×600 —— 直接塞一个 780 高的 SizedBox 会被截到 600，
  /// 于是「竖屏」用例实际跑在矮视口里（第一版就是这么假通过的）。
  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    double controlsHeight = 200,
    Widget? pinned,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorCanvasLayout(
          canvas: const SizedBox.expand(key: canvasKey),
          controls: SizedBox(height: controlsHeight, key: controlsKey),
          pinned: pinned,
        ),
      ),
    ));
  }

  testWidgets('竖屏高视口：画布吃掉剩余空间，控制面板不滚动', (tester) async {
    await pumpAt(tester, const Size(360, 780));

    final canvasRect = tester.getRect(find.byKey(canvasKey));
    final controlsRect = tester.getRect(find.byKey(controlsKey));

    expect(canvasRect.height, closeTo(780 - 200, 0.5),
        reason: '正常视口里画布应当拿满剩余高度');
    expect(controlsRect.height, 200);
    expect(find.byKey(const ValueKey('editor-controls-scroll')), findsNothing,
        reason: '高度够用时不该把控制面板塞进滚动视图');
  });

  testWidgets('横屏矮视口：画布按比例保留可用高度，控制面板可滚动', (tester) async {
    // 1080×2340 转横屏后的逻辑高度约 360dp
    await pumpAt(tester, const Size(780, 360), controlsHeight: 400);

    final canvasRect = tester.getRect(find.byKey(canvasKey));

    expect(canvasRect.height, greaterThan(150),
        reason: '矮视口下画布至少要有 150dp，否则框选水印不可用');
    expect(canvasRect.height, closeTo(360 * 0.55, 0.5));
    expect(find.byKey(const ValueKey('editor-controls-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('极矮视口（分屏下半）：画布与控制面板都还在', (tester) async {
    await pumpAt(tester, const Size(780, 240), controlsHeight: 400);

    final canvasRect = tester.getRect(find.byKey(canvasKey));
    expect(canvasRect.height, greaterThan(100));
    expect(canvasRect.height, closeTo(240 * 0.55, 0.5));
    expect(find.byKey(const ValueKey('editor-controls-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '极矮视口下也不许有溢出异常');
  });

  testWidgets('主操作固定在底部：控制面板滚得再长，按钮也还在屏幕里', (tester) async {
    const pinnedKey = ValueKey('test-pinned');
    // 横屏 + 一个远超剩余高度的控制面板（真实页面就是这样）
    await pumpAt(
      tester,
      const Size(780, 360),
      controlsHeight: 900,
      pinned: const SizedBox(height: 56, key: pinnedKey),
    );

    final pinnedRect = tester.getRect(find.byKey(pinnedKey));
    expect(pinnedRect.bottom, closeTo(360, 1),
        reason: '主按钮必须贴着视口底部，不能被滚动区带走');
    expect(pinnedRect.height, 56);

    // 控制面板确实溢出了（否则这条用例证明不了什么）
    final scroll = find.byKey(const ValueKey('editor-controls-scroll'));
    expect(tester.getSize(scroll).height, lessThan(900));
    expect(find.byKey(pinnedKey), findsOneWidget);
  });
}
