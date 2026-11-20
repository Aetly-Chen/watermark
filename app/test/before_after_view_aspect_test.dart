import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/core/widgets/before_after_view.dart';

/// 对比视图在「面板比例和图片比例差很远」时（真机横屏就是这样）的行为。
///
/// 回归的缺陷：分界线按**面板宽度**算，而画面按 contain 缩成中间一条，
/// 于是把手落在图片外面、右边那半（修复后）根本看不见 —— 真机上读起来就是「结果页坏了」。
void main() {
  Widget host({
    required Size size,
    double? aspect,
  }) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: BeforeAfterView(
              before: const ColoredBox(color: Colors.blue),
              after: const ColoredBox(color: Colors.red),
              imageAspect: aspect,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('不给比例：对比画面铺满面板（老行为不变）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(size: const Size(400, 200)));

    final split = tester.getRect(find.byKey(const ValueKey('compare-split')));
    expect(split.width, closeTo(400, 0.5));
    expect(split.height, closeTo(200, 0.5));
  });

  testWidgets('给 16:9 比例、面板很宽：对比画面收成 16:9，分界线落在图内', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 面板 1000×200（5:1），图片 16:9 —— 横屏现场就是这个形状
    await tester.pumpWidget(host(size: const Size(1000, 200), aspect: 16 / 9));

    final split = tester.getRect(find.byKey(const ValueKey('compare-split')));
    expect(split.height, closeTo(200, 0.5));
    expect(split.width, closeTo(200 * 16 / 9, 0.5), reason: '按高度收缩到图片比例');

    // 分界线必须在画面内部（旧行为会算到面板中心 = 500，落到图外）
    final divider = tester.getRect(find.byKey(const ValueKey('compare-divider')));
    final center = divider.center.dx;
    expect(center, greaterThan(split.left));
    expect(center, lessThan(split.right));
    expect(center, closeTo(split.center.dx, 1.0));
  });

  testWidgets('给 16:9 比例、面板很窄：按宽度收缩', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(size: const Size(320, 700), aspect: 16 / 9));

    final split = tester.getRect(find.byKey(const ValueKey('compare-split')));
    expect(split.width, closeTo(320, 0.5));
    expect(split.height, closeTo(320 * 9 / 16, 0.5));
  });

  group('BeforeAfterSwitch 与全屏缩放对比弹窗', () {
    Widget switchHost({
      required Size size,
      double? aspect,
      CompareMode initialMode = CompareMode.compare,
      bool enableFullscreen = true,
    }) {
      return MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: BeforeAfterSwitch(
                before: const ColoredBox(
                  key: ValueKey('src-before'),
                  color: Colors.blue,
                ),
                after: const ColoredBox(
                  key: ValueKey('src-after'),
                  color: Colors.red,
                ),
                initialMode: initialMode,
                imageAspect: aspect,
                enableFullscreen: enableFullscreen,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('点击全屏按钮打开弹窗，支持模式切换与关闭退出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        switchHost(size: const Size(320, 420), aspect: 9 / 20),
      );
      await tester.pumpAndSettle();

      final openButton = find.byKey(const ValueKey('compare-fullscreen'));
      expect(openButton, findsOneWidget);
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      final dialog = find.byType(FullscreenCompareDialog);
      expect(dialog, findsOneWidget);
      Finder inDialog(Finder inner) =>
          find.descendant(of: dialog, matching: inner);

      // 默认对比态：分界线与两层画面都在弹窗内
      expect(
        inDialog(find.byKey(const ValueKey('fullscreen-compare-divider'))),
        findsOneWidget,
      );
      expect(
        inDialog(find.byKey(const ValueKey('fullscreen-compare-after-clip'))),
        findsOneWidget,
      );
      expect(inDialog(find.byKey(const ValueKey('src-before'))), findsOneWidget);
      expect(inDialog(find.byKey(const ValueKey('src-after'))), findsOneWidget);

      // 切到「修复后」：只显示修复后，分界线与裁剪层收起
      await tester.tap(
        find.byKey(const ValueKey('fullscreen-compare-mode-after')),
      );
      await tester.pumpAndSettle();
      expect(
        inDialog(find.byKey(const ValueKey('fullscreen-compare-divider'))),
        findsNothing,
      );
      expect(
        inDialog(find.byKey(const ValueKey('fullscreen-compare-after-clip'))),
        findsNothing,
      );
      expect(inDialog(find.byKey(const ValueKey('src-after'))), findsOneWidget);
      expect(inDialog(find.byKey(const ValueKey('src-before'))), findsNothing);

      // 切到「修复前」：只显示修复前
      await tester.tap(
        find.byKey(const ValueKey('fullscreen-compare-mode-before')),
      );
      await tester.pumpAndSettle();
      expect(inDialog(find.byKey(const ValueKey('src-before'))), findsOneWidget);
      expect(inDialog(find.byKey(const ValueKey('src-after'))), findsNothing);

      // 切回「对比」：分界线恢复
      await tester.tap(
        find.byKey(const ValueKey('fullscreen-compare-mode-compare')),
      );
      await tester.pumpAndSettle();
      expect(
        inDialog(find.byKey(const ValueKey('fullscreen-compare-divider'))),
        findsOneWidget,
      );

      // 点关闭按钮正常退出
      await tester.tap(find.byKey(const ValueKey('fullscreen-compare-close')));
      await tester.pumpAndSettle();
      expect(find.byType(FullscreenCompareDialog), findsNothing);
    });

    testWidgets('竖屏高图（9:20）全屏切换「铺宽 / 适应」倍率，且分界线可拖并始终在视口内', (
      tester,
    ) async {
      // 400×640 下去掉 52dp 工具栏后可视区为 400×588（aspect ≈ 0.68），
      // 9:20（0.45）满足高竖图条件（< 0.68 * 0.72），铺宽倍率约 1.51×。
      await tester.binding.setSurfaceSize(const Size(400, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        switchHost(size: const Size(340, 460), aspect: 9 / 20),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('compare-fullscreen')));
      await tester.pumpAndSettle();

      final dialog = find.byType(FullscreenCompareDialog);
      Finder inDialog(Finder inner) =>
          find.descendant(of: dialog, matching: inner);

      expect(inDialog(find.text('1.0×')), findsOneWidget);
      expect(inDialog(find.text('铺宽')), findsOneWidget);

      final beforeAt1x = tester.getRect(
        inDialog(find.byKey(const ValueKey('src-before'))),
      );
      // 1.0× 时按高度 588 收成 9:20，宽度约 264.6
      expect(beforeAt1x.width, closeTo(588 * 9 / 20, 1.0));
      expect(beforeAt1x.height, closeTo(588, 1.0));

      // 点「铺宽」按钮：放大到铺满 400dp 宽度，文案变为「适应」
      await tester.tap(find.byKey(const ValueKey('fullscreen-compare-fit')));
      await tester.pumpAndSettle();

      expect(inDialog(find.text('1.0×')), findsNothing);
      expect(inDialog(find.text('1.5×')), findsOneWidget);
      expect(inDialog(find.text('适应')), findsOneWidget);

      final beforeFitWidth = tester.getRect(
        inDialog(find.byKey(const ValueKey('src-before'))),
      );
      expect(
        beforeFitWidth.width,
        closeTo(400, 1.0),
        reason: '铺宽后渲染宽度应贴合视口宽度 400dp',
      );
      expect(
        beforeFitWidth.height,
        greaterThan(588),
        reason: '9:20 高竖图铺宽后纵向应超过一屏，允许上下滑看',
      );
      expect(
        beforeFitWidth.top,
        closeTo(52, 1.0),
        reason: '高竖图铺宽应从画布顶部开始展示',
      );

      // 铺宽状态下：在分界线外竖向拖动平移画布，不误触分界线
      final divider = inDialog(
        find.byKey(const ValueKey('fullscreen-compare-divider')),
      );
      final dividerStartX = tester.getCenter(divider).dx;
      await tester.dragFrom(const Offset(80, 320), const Offset(0, -140));
      await tester.pumpAndSettle();

      final afterPan = tester.getRect(
        inDialog(find.byKey(const ValueKey('src-before'))),
      );
      expect(afterPan.top, lessThan(beforeFitWidth.top - 50));
      expect(
        tester.getCenter(divider).dx,
        closeTo(dividerStartX, 0.5),
        reason: '画布平移不应带动视口坐标系内的分界线',
      );

      // 铺宽状态下拖动分界线：把手与修复后裁剪层左边界同步移动，且不飞出视口
      final clipFinder = inDialog(
        find.byKey(const ValueKey('fullscreen-compare-after-clip')),
      );
      final clipBefore = tester.getRect(clipFinder).left;

      await tester.drag(divider, const Offset(100, 0));
      await tester.pumpAndSettle();

      final dividerMoved = tester.getCenter(divider).dx;
      final clipMoved = tester.getRect(clipFinder).left;
      expect(dividerMoved, greaterThan(dividerStartX + 60));
      expect(
        clipMoved,
        greaterThan(clipBefore + 60),
        reason: '修复后裁剪层应跟随分界线同步右移',
      );
      expect(dividerMoved, greaterThan(0));
      expect(dividerMoved, lessThan(400));

      // 向左右极限大幅拖动分界线：被视口边界钳位在 [0.02*vw, 0.98*vw] 内
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      final minX = tester.getCenter(divider).dx;
      expect(minX, greaterThan(0));
      expect(minX, lessThan(40));

      await tester.drag(divider, const Offset(2000, 0));
      await tester.pumpAndSettle();
      final maxX = tester.getCenter(divider).dx;
      expect(maxX, lessThan(400));
      expect(maxX, greaterThan(360));

      // 再点「适应」：回到 1.0×，按钮文字切回「铺宽」
      await tester.tap(find.byKey(const ValueKey('fullscreen-compare-fit')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('1.0×')), findsOneWidget);
      expect(inDialog(find.text('铺宽')), findsOneWidget);
      final restored = tester.getRect(
        inDialog(find.byKey(const ValueKey('src-before'))),
      );
      expect(restored.width, closeTo(588 * 9 / 20, 1.0));

      await tester.tap(find.byKey(const ValueKey('fullscreen-compare-close')));
      await tester.pumpAndSettle();
      expect(find.byType(FullscreenCompareDialog), findsNothing);
    });
  });
}
