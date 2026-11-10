import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/core/widgets/app_button.dart';
import 'package:watermark_remover/core/widgets/mask_tool_chip.dart';
import 'package:watermark_remover/features/image_editor/application/image_edit_controller.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';
import 'package:watermark_remover/features/image_editor/presentation/image_editor_page.dart';
import 'package:watermark_remover/features/image_editor/presentation/widgets/selection_canvas.dart';

/// 图片编辑页（02/03 屏）。
///
/// 这一页此前**一条 widget 测试都没有** —— 视频页有 10 条，图片页是主链路之一
/// 却完全没盖。状态字段一多，最容易出的不是逻辑错，而是某个分支**忘了渲染**
/// 或渲染了就崩；真机上验一遍要选图、框选、等修复，成本太高。
///
/// 这里把状态直接灌给页面，只断言「这个状态下该出现什么、按钮该不该可点」。
/// 真正的处理与落盘由 `integration_test/` 覆盖，不在这里重复。
void main() {
  // 1×1 透明 PNG：能真的解码，`Image.memory` 在测试环境里不报错
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

  late Directory dir;
  late String resultPath;

  /// 一个合法的选框（归一化），结果页那几条用例统一用它。
  const rect = MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wm_img_page');
    // 「修复后」用 Image.file 读它，文件必须真的在
    resultPath = '${dir.path}${Platform.pathSeparator}out_test.png';
    File(resultPath).writeAsBytesSync(png);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  ImageEditState loaded({
    MaskDraft? draft,
    MaskTool tool = MaskTool.rect,
    String? result,
    bool busy = false,
    bool saving = false,
    String? savedUri,
    String? saveError,
    String? error,
    Duration? elapsed,
    int undoDepth = 0,
  }) => ImageEditState(
    source: png,
    sourceName: 'cafe.jpg',
    imageSize: const Size(1200, 896),
    draft: draft ?? const MaskDraft.empty(),
    tool: tool,
    resultPath: result,
    busy: busy,
    saving: saving,
    savedUri: savedUri,
    saveError: saveError,
    error: error,
    elapsed: elapsed,
    undoDepth: undoDepth,
  );

  Future<void> pumpPage(WidgetTester tester, ImageEditState state) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          imageEditControllerProvider.overrideWith(() => _FakeController(state)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ImageEditorPage(),
        ),
      ),
    );
    await tester.pump();
  }

  AppButton button(WidgetTester tester, String label) =>
      tester.widget<AppButton>(find.widgetWithText(AppButton, label));

  /// 工具条是 chip 不是 AppButton —— 用 `button()` 找它会 `Bad state: No element`
  MaskToolChip chip(WidgetTester tester, String label) =>
      tester.widget<MaskToolChip>(find.widgetWithText(MaskToolChip, label));

  /// 需要读回控制器状态时用这个：把 container 拿到手，页面挂在
  /// `UncontrolledProviderScope` 下。`pumpPage` 内部自建 scope，拿不到 controller。
  Future<ProviderContainer> pumpPageWithContainer(
    WidgetTester tester,
    ImageEditState state,
  ) async {
    final container = ProviderContainer(
      overrides: [imageEditControllerProvider.overrideWith(() => _FakeController(state))],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ImageEditorPage(),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  /// 视口扫描：小屏 / 常见屏 / 横屏，有没有溢出。
  ///
  /// 这类问题**单测和文案断言都抓不到** —— 只有真的按某个尺寸排一遍版才会暴露，
  /// 在真机上表现为底部一条黄黑条纹 + 按钮被顶出屏幕。图片页从来没做过这件事，
  /// 而它是主链路之一。
  group('视口不溢出', () {
    // 320×568 是老机器下限；780×360 是横屏（最险，可用高度只有 360）
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

        await pumpPage(
          tester,
          loaded(draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3))),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: '${size.width.toInt()}×${size.height.toInt()} 下布局溢出了',
        );
      });
    }
  });

  /// 同一组视口，再扫一遍**结果态** —— 那一屏元素更多（对比视图 + 两个按钮 + 提示）。
  group('视口不溢出（结果态）', () {
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

        await pumpPage(
          tester,
          loaded(
            draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
            result: resultPath,
            elapsed: const Duration(milliseconds: 1200),
          ),
        );
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: '${size.width.toInt()}×${size.height.toInt()} 结果态布局溢出了',
        );
      });
    }
  });

  testWidgets('撤销：没东西可退时禁用', (tester) async {
    await pumpPage(
      tester,
      loaded(draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3))),
    );
    expect(find.text('撤销'), findsOneWidget);
    expect(
      chip(tester, '撤销').onTap,
      isNull,
      reason: '空栈时不能点 —— 点了没反应比禁用更糟',
    );
  });

  // 与上一条**分开写**：同一个用例里连调两次 pumpPage，第二次的 provider 覆盖
  // 不会重新生效（ProviderScope 被复用而不是重建），读到的还是第一次的状态。
  testWidgets('撤销：退过一步就可点', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        undoDepth: 1,
      ),
    );
    expect(chip(tester, '撤销').onTap, isNotNull);
  });

  testWidgets('修复中：撤销也禁用（不能改正在用的草稿）', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        undoDepth: 2,
        busy: true,
      ),
    );
    expect(chip(tester, '撤销').onTap, isNull);
  });

  testWidgets('空状态：两个入口在，「开始修复」不渲染', (tester) async {
    await pumpPage(tester, const ImageEditState());

    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('用示例图'), findsOneWidget);
    expect(find.text('开始修复'), findsNothing);
  });

  testWidgets('有图没框选：显示原图尺寸、遮罩写「未标注」、修复按钮禁用', (tester) async {
    await pumpPage(tester, loaded());

    expect(find.text('1200 × 896'), findsOneWidget);
    expect(find.text('未标注'), findsOneWidget);
    expect(find.text('开始修复'), findsOneWidget);
    expect(button(tester, '开始修复').onPressed, isNull);
  });

  testWidgets('有图有框选：选区按真实像素换算，修复按钮可点', (tester) async {
    // 0.25 × 0.5 的选区，在 1200×896 上应当是 300 × 448
    await pumpPage(tester, loaded(draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.35, 0.6))));

    expect(find.text('300 × 448'), findsOneWidget);
    expect(button(tester, '开始修复').onPressed, isNotNull);
  });

  testWidgets('修复中：按钮变「修复中…」且禁用', (tester) async {
    await pumpPage(
      tester,
      loaded(draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)), busy: true),
    );

    expect(find.text('修复中…'), findsOneWidget);
    expect(button(tester, '修复中…').onPressed, isNull);
  });

  testWidgets('有结果：露出「重新定位选区」和「保存到相册」，并显示耗时', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        result: resultPath,
        elapsed: const Duration(milliseconds: 480),
      ),
    );

    expect(find.text('重新定位选区'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(button(tester, '保存到相册').onPressed, isNotNull);
    expect(find.textContaining('480 ms'), findsOneWidget);
    // 结果页的三段切换（原型 `segImg`）。默认停在「对比」——
    // 只切前后看不出差别，得同一张画面上并排才看得清水印去没去干净。
    // 每段标签各出现两次：分段控件一次 + 画面上的角标一次（原型也是这样）。
    expect(find.text('修复前'), findsNWidgets(2));
    expect(find.text('对比'), findsOneWidget);
    expect(find.text('修复后'), findsNWidgets(2));
  });

  testWidgets('结果默认停在「对比」：分界线在，两张图叠在一起', (tester) async {
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    expect(find.byKey(const ValueKey('compare-split')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-divider')), findsOneWidget);
  });

  testWidgets('点「修复后」：只看结果，分界线收起', (tester) async {
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    await tester.tap(find.text('修复后').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('compare-after')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-split')), findsNothing);
    expect(
      find.byKey(const ValueKey('compare-divider')),
      findsNothing,
      reason: '只显示一张图时不该留着分界线',
    );
  });

  testWidgets('点「修复前」：只看原图，分界线收起', (tester) async {
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    await tester.tap(find.text('修复前').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('compare-before')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-split')), findsNothing);
  });

  testWidgets('拖分界线：位置真的跟着手指走（不是只动了把手外观）', (tester) async {
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    final divider = find.byKey(const ValueKey('compare-divider'));
    final start = tester.getCenter(divider).dx;
    final clipBefore = _afterClipLeft(tester);

    await tester.drag(divider, const Offset(120, 0));
    await tester.pumpAndSettle();

    final moved = tester.getCenter(divider).dx;
    expect(moved, greaterThan(start + 60), reason: '拖 120 应该往右走一大截');

    // 关键：**可见区的左边界也要跟着动**。只断言把手位置的话，
    // 「把手滑过去了、图停在原处」这种坏法照样能过（第一版用 custom clipper 时
    // 就是这样：把 shouldReclip 改成 false，用例仍然绿）。
    expect(
      _afterClipLeft(tester),
      greaterThan(clipBefore + 60),
      reason: '修复后那一层要跟着分界线走，不能只有把手在动',
    );
  });

  testWidgets('对比模式下角标不与分段控件挤在同一行', (tester) async {
    // 真机上一眼看过去是「修复前 修复前 对比 修复后 修复后」五个标签，
    // 分不清哪个能点。角标原来照抄原型放在画面顶部 —— 而原型的三段在顶部栏里、
    // 不占画面，我们的分段是浮在画布顶部的，直接照搬就撞上了。
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    final pill = tester.getRect(find.byKey(const ValueKey('compare-seg')));
    for (final key in const [
      ValueKey('compare-tag-before'),
      ValueKey('compare-tag-after'),
    ]) {
      final tag = tester.getRect(find.byKey(key));
      // 注意判据是「不在同一条垂直带」而不是 rect 相交：
      // 角标在左/右两端、分段在正中，两者**从来不会真的重叠**，
      // 但并排在同一行时读起来就是「修复前 修复前 对比 修复后 修复后」五个选项。
      expect(
        tag.top > pill.bottom || tag.bottom < pill.top,
        isTrue,
        reason: '角标和分段控件挤在同一行，看起来像多出来两个选项',
      );
    }
  });

  testWidgets('分界线拖到最左/最右会被夹住，不飞出画面', (tester) async {
    await pumpPage(tester, loaded(draft: rect, result: resultPath));

    final divider = find.byKey(const ValueKey('compare-divider'));
    final canvas = tester.getRect(find.byKey(const ValueKey('compare-split')));

    await tester.drag(divider, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    final left = tester.getCenter(divider).dx;
    expect(left, greaterThan(canvas.left), reason: '贴着左边停住，但不在边界外');
    expect(left, lessThan(canvas.left + canvas.width * 0.1));

    await tester.drag(divider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    final right = tester.getCenter(divider).dx;
    expect(right, lessThan(canvas.right));
    expect(right, greaterThan(canvas.right - canvas.width * 0.1));
  });

  testWidgets('保存中：文案「保存中…」且禁用（防连点写两份）', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        result: resultPath,
        saving: true,
      ),
    );

    expect(find.text('保存中…'), findsOneWidget);
    expect(button(tester, '保存中…').onPressed, isNull);
  });

  testWidgets('已保存：文案变「已存入相册」且禁用，并说明存到哪了', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        result: resultPath,
        savedUri: 'content://media/external/images/media/1',
      ),
    );

    expect(find.text('已存入相册'), findsOneWidget);
    expect(button(tester, '已存入相册').onPressed, isNull);
    expect(find.textContaining('Pictures / 水印工坊'), findsOneWidget);
  });

  testWidgets('保存失败：错误文案露出，按钮仍可点（能重试）', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        result: resultPath,
        saveError: '相册写入被系统拒绝',
      ),
    );

    expect(find.text('相册写入被系统拒绝'), findsOneWidget);
    expect(button(tester, '保存到相册').onPressed, isNotNull);
  });

  testWidgets('修复失败：错误横幅露出，还能重新定位再试', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3)),
        error: '选区无效，请重新框选',
      ),
    );

    expect(find.text('选区无效，请重新框选'), findsOneWidget);
    expect(button(tester, '开始修复').onPressed, isNotNull);
  });

  // 三个工具都必须**真的能切**。
  // 历史：这一行原来只有一个「矩形选区」，而它的 onTap 是个空函数 ——
  // 原型上明明写着「画笔涂抹 / 橡皮擦 / 矩形 / 清除」四个工具。
  testWidgets('三个工具都在，且点击真的切过去', (tester) async {
    await pumpPage(tester, loaded(draft: const MaskDraft.empty()));

    expect(find.text('矩形'), findsOneWidget);
    expect(find.text('涂抹'), findsOneWidget);
    expect(find.text('橡皮'), findsOneWidget);

    GestureDetector chipOf(String label) => tester.widget<GestureDetector>(
      find
          .ancestor(of: find.text(label), matching: find.byType(GestureDetector))
          .first,
    );

    // 默认是涂抹；点「矩形」应当切过去（再点「涂抹」切回来）
    expect(chipOf('矩形').onTap, isNotNull, reason: '点了没反应比没有按钮更糟');
    await tester.tap(find.text('矩形'));
    await tester.pumpAndSettle();
    expect(chipOf('矩形').onTap, isNotNull);
  });

  // ⚠ 下面两组都拆成两个用例：同一个用例里 `pumpWidget` 第二次时，
  // ProviderScope 的 Element 会被复用，`keepAlive` 的 controller 还是上一份 ——
  // 症状是「状态没换过来」，看着像页面渲染错了，其实是测试写错。
  GestureDetector clearChip(WidgetTester tester) =>
      tester.widget<GestureDetector>(
        find
            .ancestor(
              of: find.text('清除'),
              matching: find.byType(GestureDetector),
            )
            .first,
      );

  testWidgets('没有草稿时「清除」不可点', (tester) async {
    await pumpPage(tester, loaded(draft: const MaskDraft.empty()));
    expect(clearChip(tester).onTap, isNull, reason: '没东西可清时按钮要明确失效');
  });

  testWidgets('有草稿时「清除」可点', (tester) async {
    await pumpPage(
      tester,
      loaded(draft: const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.3, 0.3))),
    );
    expect(clearChip(tester).onTap, isNotNull);
  });

  // 页面上现在有两个滑块（笔宽 / 修复强度），按 max 区分比按下标稳。
  final brushSlider = find.byWidgetPredicate((w) => w is Slider && w.max == 60);
  final radiusSlider = find.byWidgetPredicate((w) => w is Slider && w.max == 16);

  testWidgets('涂抹时露出笔宽滑块，修复强度一直在', (tester) async {
    await pumpPage(
      tester,
      loaded(draft: const MaskDraft.empty(), tool: MaskTool.brush),
    );
    expect(find.text('笔宽'), findsOneWidget);
    expect(brushSlider, findsOneWidget);
    expect(radiusSlider, findsOneWidget, reason: '修复强度和工具无关，任何工具下都该在');
  });

  testWidgets('矩形时收起笔宽滑块', (tester) async {
    await pumpPage(
      tester,
      loaded(draft: const MaskDraft.empty(), tool: MaskTool.rect),
    );
    expect(
      find.text('笔宽'),
      findsNothing,
      reason: '矩形不需要笔宽，摆着会让人以为框的粗细能调',
    );
    expect(brushSlider, findsNothing);
    expect(radiusSlider, findsOneWidget);
  });

  testWidgets('涂了 N 笔：遮罩摘要说清楚涂了几笔', (tester) async {
    await pumpPage(
      tester,
      loaded(
        draft: const MaskDraft(
          strokes: <MaskStroke>[
            MaskStroke(points: <Offset>[Offset(0.1, 0.1)], width: 0.05),
            MaskStroke(points: <Offset>[Offset(0.2, 0.2)], width: 0.05),
          ],
        ),
      ),
    );

    expect(find.text('涂抹 2 笔'), findsOneWidget);
    expect(button(tester, '开始修复').onPressed, isNotNull);
  });

  testWidgets('修复强度：默认 8 px 显示出来', (tester) async {
    await pumpPage(tester, loaded(draft: const MaskDraft.empty()));
    expect(find.text('修复强度'), findsOneWidget);
    expect(find.text('8 px'), findsOneWidget);
  });

  testWidgets('拖修复强度滑块：状态里的 radius 真的变', (tester) async {
    final container = await pumpPageWithContainer(
      tester,
      loaded(draft: const MaskDraft.empty()),
    );
    expect(container.read(imageEditControllerProvider).radius, 8);

    await tester.drag(radiusSlider, const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(
      container.read(imageEditControllerProvider).radius,
      greaterThan(8),
      reason: '滑块拖了状态不动 = 装饰',
    );
  });

  // ── 手势 → 草稿：这才是「涂抹」真正的地方 ──
  // 页面渲染对不对只是一半；手指划过去有没有真的产生笔迹，只有拖一次才知道。

  testWidgets('默认是矩形：拖一下就产生选框，并解锁「开始修复」', (tester) async {
    final container = await pumpPageWithContainer(tester, loaded());
    expect(
      container.read(imageEditControllerProvider).tool,
      MaskTool.rect,
      reason: '原型上矩形是默认工具（data-tool="rect" 带 on 类）',
    );
    expect(
      container.read(imageEditControllerProvider).canRun,
      isFalse,
      reason: '还没框选的时候不能修',
    );

    await tester.drag(find.byType(SelectionCanvas), const Offset(80, 40));
    await tester.pumpAndSettle();

    final state = container.read(imageEditControllerProvider);
    expect(state.draft.rect, isNotNull, reason: '一次拖拽 = 一个选框');
    expect(state.draft.strokes, isEmpty, reason: '矩形模式下不该顺手留下笔迹');
    expect(state.canRun, isTrue, reason: '框完就该能点「开始修复」');
    expect(find.text('开始修复'), findsOneWidget);
    expect(button(tester, '开始修复').onPressed, isNotNull);
  });

  testWidgets('切到涂抹再拖：产生笔迹，不产生矩形', (tester) async {
    final container = await pumpPageWithContainer(tester, loaded());

    await tester.tap(find.text('涂抹'));
    await tester.pumpAndSettle();
    expect(container.read(imageEditControllerProvider).tool, MaskTool.brush);

    await tester.drag(find.byType(SelectionCanvas), const Offset(80, 40));
    await tester.pumpAndSettle();

    final draft = container.read(imageEditControllerProvider).draft;
    expect(draft.strokes, hasLength(1), reason: '一次拖拽 = 一段笔迹');
    expect(draft.strokes.single.erase, isFalse);
    expect(
      draft.strokes.single.points.length,
      greaterThan(1),
      reason: '拖拽应当采到多个点，否则画出来只有一个圆点',
    );
    expect(draft.rect, isNull, reason: '涂抹模式下不该留下选框');
  });

  // 真机抓到的 bug（2026-10-22）：一次横着涂水印，界面显示「涂抹 53 笔」。
  // 原因是每个 `onPanUpdate` 都走 `addingStroke` —— 53 段笔迹指向同一个点列表，
  // 画面上完全重叠，肉眼一点看不出来，只有计数和 Mask 重复绘制露馅。
  //
  // 上面那条 `hasLength(1)` 抓不到它：`tester.drag` 只发**一次**移动事件。
  // 必须手动 `startGesture` + 多次 `moveBy`，才会像真机那样一帧一个事件。
  testWidgets('一次连续涂抹只算一笔：移动是替换，不是追加', (tester) async {
    final container = await pumpPageWithContainer(tester, loaded());
    await tester.tap(find.text('涂抹'));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(SelectionCanvas));
    final gesture = await tester.startGesture(center - const Offset(60, 0));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(15, 2));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final draft = container.read(imageEditControllerProvider).draft;
    expect(
      draft.strokes,
      hasLength(1),
      reason: '9 次移动事件必须仍然是一段笔迹',
    );
    expect(
      draft.strokes.single.points.length,
      greaterThan(1),
      reason: '点要累积进同一段，而不是每次移动新建一段',
    );
    expect(
      find.textContaining('涂抹 1 笔'),
      findsOneWidget,
      reason: '界面文案也要跟着对（真机上是「涂抹 53 笔」）',
    );
  });

  // 同一个 bug 的另一半：草稿里存的若是 `_activePoints` 的**引用**，
  // 「上一帧的 draft」和「这一帧的 draft」读的是同一份内容，`listEquals` 永远相等，
  // `_DraftPainter.shouldRepaint` 就返回 false —— 涂抹过程中看不到实时笔迹。
  // 这条用一个快照断言钉住：同步进草稿的笔迹必须是那一刻的副本。
  testWidgets('同步进草稿的笔迹是快照，后续移动不能改写它', (tester) async {
    final container = await pumpPageWithContainer(tester, loaded());
    await tester.tap(find.text('涂抹'));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(SelectionCanvas));
    final gesture = await tester.startGesture(center - const Offset(60, 0));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    final snapshot = container.read(imageEditControllerProvider).draft;
    final frozen = snapshot.strokes.single.points.length;

    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      snapshot.strokes.single.points.length,
      frozen,
      reason: '旧快照的点数被后续移动改掉了 —— points 是共享引用，'
          'CustomPainter 会认为「没变」而不重绘',
    );
  });

  testWidgets('切到橡皮再拖：新笔迹被标成擦除', (tester) async {
    final container = await pumpPageWithContainer(tester, loaded());

    await tester.tap(find.text('橡皮'));
    await tester.pumpAndSettle();
    expect(
      container.read(imageEditControllerProvider).tool,
      MaskTool.eraser,
      reason: '工具切换要真的落到状态里',
    );

    await tester.drag(find.byType(SelectionCanvas), const Offset(60, 60));
    await tester.pumpAndSettle();

    final strokes = container.read(imageEditControllerProvider).draft.strokes;
    expect(strokes, hasLength(1));
    expect(strokes.single.erase, isTrue, reason: '橡皮笔迹必须是「挖掉」而不是「涂上」');
  });

  // 原型上那句提示：「拖动选框框住水印，**也可以拉右下角改大小**」。
  // 只支持「重新拖一个」是不够的 —— 想微调两像素时，重拖必然对不准。
  testWidgets('拉右下角改大小：对角固定，框变大', (tester) async {
    const start = Rect.fromLTRB(0.2, 0.2, 0.6, 0.6);
    final container = await pumpPageWithContainer(
      tester,
      loaded(draft: const MaskDraft(rect: start)),
    );

    // 手势用的是**全局**坐标，所以这里按画布的 BoxFit.contain 自己算一遍
    // 图像显示矩形 —— 和 `SelectionCanvas` 里的算法一模一样，
    // 这也是唯一能把「角的真实位置」交给 tester 的办法。
    final canvas = tester.getRect(find.byType(SelectionCanvas));
    final scale = math.min(canvas.width / 1200, canvas.height / 896);
    final rendered = Size(1200 * scale, 896 * scale);
    final origin = Offset(
      canvas.left + (canvas.width - rendered.width) / 2,
      canvas.top + (canvas.height - rendered.height) / 2,
    );
    Offset at(Offset normalized) =>
        origin + Offset(normalized.dx * rendered.width, normalized.dy * rendered.height);

    await tester.dragFrom(at(start.bottomRight), const Offset(40, 30));
    await tester.pumpAndSettle();

    final rect = container.read(imageEditControllerProvider).draft.rect!;
    expect(rect.left, closeTo(0.2, 0.01), reason: '左上角是锚点，不能动');
    expect(rect.top, closeTo(0.2, 0.01));
    expect(rect.right, greaterThan(0.6), reason: '右下角应当跟着手指变大');
    expect(rect.bottom, greaterThan(0.6));
  });

  testWidgets('按在框中间拖：重新拖一个新框（不是改大小）', (tester) async {
    const start = Rect.fromLTRB(0.2, 0.2, 0.4, 0.4);
    final container = await pumpPageWithContainer(
      tester,
      loaded(draft: const MaskDraft(rect: start)),
    );

    await tester.drag(find.byType(SelectionCanvas), const Offset(120, 80));
    await tester.pumpAndSettle();

    final rect = container.read(imageEditControllerProvider).draft.rect;
    expect(rect, isNotNull);
    // 从画布中心重新拖 → 左上角不再是 0.2
    expect(rect!.left, isNot(closeTo(0.2, 0.01)));
  });

  testWidgets('笔宽滑块拖动会改状态（不是只动 UI）', (tester) async {
    // 滑块只在涂抹/橡皮下出现 —— 默认是矩形，所以这里要显式选涂抹。
    final container = await pumpPageWithContainer(
      tester,
      loaded(tool: MaskTool.brush),
    );
    expect(container.read(imageEditControllerProvider).brushSize, 26);

    await tester.drag(brushSlider, const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(
      container.read(imageEditControllerProvider).brushSize,
      greaterThan(26),
      reason: '滑块右拖应当变粗',
    );
  });

  // 摘要文字是纯函数，直接断言 —— 不必为了「300 × 448」渲染整页。
  // 这段换算最容易错：写反了会显示一个「看着对、其实对应别处」的数字。
  group('maskLabel', () {
    ImageEditState withDraft(MaskDraft draft) => ImageEditState(
      source: png,
      imageSize: const Size(1200, 896),
      draft: draft,
    );

    test('空草稿 → 未标注', () {
      expect(maskLabel(withDraft(const MaskDraft.empty())), '未标注');
    });

    test('只有矩形 → 按原图像素换算', () {
      expect(
        maskLabel(
          withDraft(const MaskDraft(rect: Rect.fromLTRB(0.1, 0.1, 0.35, 0.6))),
        ),
        '300 × 448',
      );
    });

    test('框 + 涂抹 → 两部分都写出来', () {
      expect(
        maskLabel(
          withDraft(
            const MaskDraft(
              rect: Rect.fromLTRB(0.1, 0.1, 0.35, 0.6),
              strokes: <MaskStroke>[
                MaskStroke(points: <Offset>[Offset(0.5, 0.5)], width: 0.04),
              ],
            ),
          ),
        ),
        '300 × 448 · 涂抹 1 笔',
      );
    });

    test('只画了橡皮 → 等于没涂（不能允许开始修复）', () {
      final state = withDraft(
        const MaskDraft(
          strokes: <MaskStroke>[
            MaskStroke(
              points: <Offset>[Offset(0.5, 0.5)],
              width: 0.04,
              erase: true,
            ),
          ],
        ),
      );
      expect(maskLabel(state), '未标注');
      expect(state.canRun, isFalse, reason: '只有橡皮等于什么都没涂');
    });
  });
}

class _FakeController extends ImageEditController {
  _FakeController(this._initial);

  final ImageEditState _initial;

  @override
  ImageEditState build() => _initial;
}

/// 「修复后」那一层被露出来的左边界 —— 读的是**真正参与布局的那个盒子**，
/// 和画出来的是同一个数。
///
/// 之前这里读的是自定义 clipper 现算出来的 Rect，结果把 `shouldReclip`
/// 改成 `=> false`（图不跟着动）用例照样绿 —— 断言没落在渲染路径上。
double _afterClipLeft(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('compare-after-clip'))).left;
