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
}
