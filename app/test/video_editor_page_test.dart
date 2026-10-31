import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/video_probe.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/features/video_editor/application/video_edit_controller.dart';
import 'package:watermark_remover/features/video_editor/presentation/video_editor_page.dart';

/// 视频编辑页的渲染验证。
///
/// 为什么值得写：这一页的三个状态（空 / 转码中 / 有结果）都由 `VideoEditState` 驱动，
/// 状态字段一多，最容易出的 bug 不是逻辑错，而是**某个分支忘了渲染**或**渲染了就崩**。
/// 真机上点进去要经过选片、探测、框选，成本太高；这里直接把三种状态灌给页面。
///
/// 不测的：平台的编解码（`VideoRepairer` 走 MethodChannel，真机 `integration_test` 已覆盖）。
/// 这里只到「页面在这三种状态下不抛异常、该出现的文案出现」为止。
void main() {
  const meta = VideoMeta(
    path: '/tmp/sample.mp4',
    width: 960,
    height: 540,
    rotation: 0,
    displayWidth: 960,
    displayHeight: 540,
    duration: Duration(milliseconds: 5056),
    hasAudio: true,
    sizeBytes: 1128375,
  );

  // 1×1 的透明 PNG。`SelectionCanvas` 只是把它交给 Image.memory，
  // 测试环境不真的解码也能渲染出布局。
  final posterBytes = Uint8List.fromList([
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

  Future<void> pumpPage(
    WidgetTester tester,
    VideoEditState state, {
    _FakeController? controller,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoEditControllerProvider.overrideWith(
            () => controller ?? _FakeController(state),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const VideoEditorPage(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('空状态：两个入口按钮都在，「开始修复」不渲染', (tester) async {
    await pumpPage(tester, const VideoEditState());

    expect(find.text('还没有选视频'), findsOneWidget);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(find.text('用示例视频'), findsOneWidget);
    expect(find.textContaining('开始修复'), findsNothing);
  });

  testWidgets('有视频但没框选：按钮在但禁用', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
      ),
    );

    expect(find.text('封面帧 · 框选水印位置'), findsOneWidget);
    expect(find.text('00:05'), findsOneWidget); // 时长 5056ms → durationLabel
    expect(find.text('有'), findsOneWidget); // 音轨
    expect(find.text('开始修复'), findsOneWidget);

    // 没框选 → 不能点。用 InkWell 的 onTap 判断，比找 Opacity 稳。
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: find.text('开始修复'), matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNull, reason: '没有选区时「开始修复」必须是禁用的');
  });

  testWidgets('转码中：显示帧进度，按钮变成「取消修复」', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        processing: true,
        progressDone: 60,
        progressTotal: 151,
        taskId: 't1',
      ),
    );

    expect(find.text('逐帧修复'), findsOneWidget);
    expect(find.text('60 / 约 151 帧'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget); // 60/151 = 39.7% → 四舍五入 40
    expect(find.text('取消修复'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 关着跟随时没有第一趟，「分析镜头运动」不该出现
    expect(find.text('分析镜头运动'), findsNothing);
    // 还没修完，没有结果可播
    expect(find.text('预览效果'), findsNothing);
  });

  testWidgets('跟随开启：进度卡是两条，第一趟做完不等于第二趟开始', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        processing: true,
        trackMotion: true,
        phase: VideoRepairPhase.repair,
        motionDone: 150,
        motionTotal: 150,
        motionFinished: true,
        progressDone: 30,
        progressTotal: 150,
        taskId: 't1',
      ),
    );

    expect(find.text('分析镜头运动'), findsOneWidget);
    expect(find.text('逐帧修复'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('全片 150 帧'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget); // 30/150
    // 第一趟已经数出真帧数，第二趟的分母就不是估计值了，不该再写「约」
    expect(find.text('30 / 150 帧'), findsOneWidget);
    expect(find.text('30 / 约 150 帧'), findsNothing);

    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    expect(bars, hasLength(2), reason: '两条进度条：分析一趟、修复一趟');
    expect(bars[0].value, 1.0, reason: '第一趟该是满的');
    expect(bars[1].value, closeTo(0.2, 1e-9));
  });

  testWidgets('跟随开启但第一趟还没跑完：修复那条是「等待」，不是 0% 假装跑', (
    tester,
  ) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        processing: true,
        trackMotion: true,
        phase: VideoRepairPhase.motion,
        motionDone: 30,
        motionTotal: 150,
        taskId: 't1',
      ),
    );

    expect(find.text('30 / 约 150 帧'), findsOneWidget);
    expect(find.text('等待'), findsOneWidget);
    expect(find.text('等待第一趟跑完'), findsOneWidget);
    final bars = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .toList();
    // 判据是「空条」而不是「null」：null 在真机上是不确定态动画，
    // 会滚出一条几乎满格的橙条（截图抓到过），比空着更误导。
    expect(bars[1].value, 0.0, reason: '还没开始就该是一条空条，不是滚动的动画');
  });

  testWidgets('修完且拿到首帧：画布换成「修复前 / 对比 / 修复后」', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        result: const VideoRepairResult(
          outputPath: '/tmp/fixed.mp4',
          width: 960,
          height: 540,
          rotation: 0,
          frames: 150,
          skippedFrames: 0,
          videoBytes: 1397148,
          audioBytes: 161792,
          hasAudio: true,
          maskPixels: 15824,
          sizeBytes: 1562172,
          elapsed: Duration(milliseconds: 5000),
        ),
        // 输出视频的首帧（内容和封面帧不同不重要，这里只验渲染分支）
        resultFrame: posterBytes,
        resultFrameSize: const Size(960, 540),
      ),
    );

    expect(find.byKey(const ValueKey('compare-split')), findsOneWidget);
    expect(
      find.text('封面帧 · 框选水印位置'),
      findsNothing,
      reason: '修完还摆着带水印的封面帧和选框，用户会以为没修干净',
    );
  });

  testWidgets('换一个新结果：对比视图回到默认的「对比」，不带上一件的态', (tester) async {
    VideoEditState withResult(String path) => VideoEditState(
      videoPath: meta.path,
      meta: meta,
      poster: posterBytes,
      posterSize: const Size(960, 540),
      selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
      result: VideoRepairResult(
        outputPath: path,
        width: 960,
        height: 540,
        rotation: 0,
        frames: 150,
        skippedFrames: 0,
        videoBytes: 1397148,
        audioBytes: 161792,
        hasAudio: true,
        maskPixels: 15824,
        sizeBytes: 1562172,
        elapsed: const Duration(milliseconds: 5000),
      ),
      resultFrame: posterBytes,
      resultFrameSize: const Size(960, 540),
    );

    final fake = _FakeController(withResult('/tmp/a.mp4'));
    await pumpPage(tester, withResult('/tmp/a.mp4'), controller: fake);
    expect(find.byKey(const ValueKey('compare-split')), findsOneWidget);

    // 用户切到「修复后」只看结果
    await tester.tap(find.byKey(const ValueKey('compare-mode-after')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compare-split')), findsNothing);

    // 又修完一件 —— 新结果必须重新从「对比」开始
    fake.swap(withResult('/tmp/b.mp4'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('compare-split')),
      findsOneWidget,
      reason: '新结果还停在上一件的「修复后」，用户第一眼看不到对比',
    );
  });

  testWidgets('有结果但首帧没取到：退回封面帧，不崩也不空着', (tester) async {
    // 抽帧失败（原生不支持该容器、或临时目录写不进）只是没有对比图，
    // 不该让一次成功的修复看起来像失败。
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        result: const VideoRepairResult(
          outputPath: '/tmp/fixed.mp4',
          width: 960,
          height: 540,
          rotation: 0,
          frames: 150,
          skippedFrames: 0,
          videoBytes: 1397148,
          audioBytes: 161792,
          hasAudio: true,
          maskPixels: 15824,
          sizeBytes: 1562172,
          elapsed: Duration(milliseconds: 5000),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('compare-split')), findsNothing);
    expect(find.text('封面帧 · 框选水印位置'), findsOneWidget);
    expect(find.text('修复完成'), findsOneWidget);
  });

  testWidgets('手机竖屏 360×800：出结果后不溢出，保存与重新修复都够得着', (tester) async {
    // 默认测试视口是 800×600（宽而矮），手机是 360×800（窄而高）。
    // 结果态底部同时挂着元信息 Wrap + 结果卡 + 保存按钮 + 选区提示 + 跟随开关 + 主按钮，
    // 这一屏到底装不装得下，800×600 那个视口是看不出来的。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        result: const VideoRepairResult(
          outputPath: '/tmp/fixed.mp4',
          width: 960,
          height: 540,
          rotation: 0,
          frames: 150,
          skippedFrames: 3,
          videoBytes: 1397148,
          audioBytes: 161792,
          hasAudio: true,
          maskPixels: 15824,
          sizeBytes: 1562172,
          elapsed: Duration(milliseconds: 56074),
        ),
        resultFrame: posterBytes,
        resultFrameSize: const Size(960, 540),
      ),
    );

    // 主色按钮真的在屏幕里，且高度没被压扁（压扁 = 布局在硬挤）
    for (final label in const ['预览效果', '保存到相册', '重新修复']) {
      final rect = tester.getRect(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
      );
      expect(rect.bottom, lessThanOrEqualTo(800), reason: '「$label」被挤出屏幕底部');
      expect(rect.height, greaterThan(36), reason: '「$label」被压扁了');
    }

    // 「预览效果 / 保存到相册」是并排的：不能叠在一起，也不能窄到文字放不下
    Rect rectOf(String label) => tester.getRect(
      find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
    );
    final preview = rectOf('预览效果');
    final save = rectOf('保存到相册');
    expect(
      preview.right,
      lessThanOrEqualTo(save.left),
      reason: '两个按钮压在一起了',
    );
    expect(preview.width, greaterThan(120), reason: '并排后太窄，文案会被截断');
    expect(save.width, greaterThan(120), reason: '并排后太窄，文案会被截断');

    // 分段控件在窄屏上仍然是一行（被挤成两行时高度会翻倍）
    final seg = tester.getRect(find.byKey(const ValueKey('compare-seg')));
    expect(seg.height, lessThan(50), reason: '三段被挤成了多行');
    expect(seg.right, lessThanOrEqualTo(360), reason: '分段控件超出屏幕右边界');
  });

  testWidgets('有结果：露出帧数、体积、音轨与跳过帧数', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        result: const VideoRepairResult(
          outputPath: '/tmp/fixed.mp4',
          width: 960,
          height: 540,
          rotation: 0,
          frames: 150,
          skippedFrames: 3,
          videoBytes: 1397148,
          audioBytes: 161792,
          hasAudio: true,
          maskPixels: 15824,
          sizeBytes: 1562172,
          elapsed: Duration(milliseconds: 56074),
        ),
      ),
    );

    expect(find.text('修复完成'), findsOneWidget);
    expect(find.textContaining('960 × 540 · 150 帧'), findsOneWidget);
    expect(find.textContaining('音轨保留'), findsOneWidget);
    expect(find.textContaining('跳过 3 帧'), findsOneWidget);
    expect(find.text('重新修复'), findsOneWidget);
  });

  // ---- 保存到相册 ----
  //
  // 修复结果落在临时目录，系统随时回收。这一组断言盯的是「修完之后拿不拿得出来」：
  // 按钮必须在、点得动、点完不让人重复点、失败时能重试。
  // 平台侧（MediaStore 写入）只能在真机上验，这里只到「控件状态与文案」为止。

  /// 结果态的最小状态：只填 `result`，其余走默认值。
  VideoEditState resultState({bool saving = false, String? savedUri, String? saveError}) {
    return VideoEditState(
      videoPath: meta.path,
      meta: meta,
      poster: posterBytes,
      posterSize: const Size(960, 540),
      selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
      result: const VideoRepairResult(
        outputPath: '/tmp/fixed.mp4',
        width: 960,
        height: 540,
        rotation: 0,
        frames: 150,
        skippedFrames: 0,
        videoBytes: 1397148,
        audioBytes: 161792,
        hasAudio: true,
        maskPixels: 15824,
        sizeBytes: 1562172,
        elapsed: Duration(milliseconds: 56074),
      ),
      saving: saving,
      savedUri: savedUri,
      saveError: saveError,
    );
  }

  /// 取某个文案所在按钮的 onTap。禁用的按钮在 `AppButton` 里就是 `onTap == null`，
  /// 比看 Opacity 0.45 稳。
  VoidCallback? tapOf(WidgetTester tester, String label) {
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
    );
    return inkWell.onTap;
  }

  testWidgets('有结果：露出「保存到相册」且可点', (tester) async {
    await pumpPage(tester, resultState());

    expect(find.text('保存到相册'), findsOneWidget);
    expect(
      tapOf(tester, '保存到相册'),
      isNotNull,
      reason: '修完不给保存入口，等于这次修复白做',
    );
  });

  testWidgets('有结果：露出「预览效果」，能播整段而不只是一帧', (tester) async {
    await pumpPage(tester, resultState());

    expect(find.text('预览效果'), findsOneWidget);
    expect(
      tapOf(tester, '预览效果'),
      isNotNull,
      reason: '只有首帧对比时，跟随时抖不抖、有没有跳帧都看不出来',
    );
  });

  testWidgets('保存中：文案变「正在保存…」且禁用（防连点写两份）', (tester) async {
    await pumpPage(tester, resultState(saving: true));

    expect(find.text('正在保存…'), findsOneWidget);
    expect(find.text('保存到相册'), findsNothing);
    expect(tapOf(tester, '正在保存…'), isNull);
  });

  testWidgets('已保存：文案变「已保存到相册」且禁用（相册里不该有两份）', (tester) async {
    await pumpPage(
      tester,
      resultState(savedUri: 'content://media/external/video/media/1234'),
    );

    expect(find.text('已保存到相册'), findsOneWidget);
    expect(find.text('保存到相册'), findsNothing);
    expect(tapOf(tester, '已保存到相册'), isNull);
  });

  testWidgets('保存失败：错误文案露出，按钮仍可点（能重试）', (tester) async {
    await pumpPage(tester, resultState(saveError: '保存失败：存储空间不足'));

    expect(find.textContaining('存储空间不足'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
    expect(
      tapOf(tester, '保存到相册'),
      isNotNull,
      reason: '保存失败必须能重来一次，不能把按钮一起锁死',
    );
  });

  testWidgets('跟随开关：默认「水印静止」，点一下变「跟随画面」', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
      ),
    );

    expect(find.text('水印静止'), findsOneWidget);
    expect(find.text('跟随画面'), findsNothing);
    expect(
      tester.widget<Switch>(find.byType(Switch)).value,
      isFalse,
      reason: '跟随必须默认关闭 —— 真实素材上的可信度还没建立',
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(find.text('跟随画面'), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byType(Switch)).value,
      isTrue,
      reason: '点一下没有把状态翻过去',
    );
  });

  testWidgets('转码中：跟随开关收起（改的是下一次的行为，别让人误会）', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        processing: true,
        taskId: 't1',
      ),
    );

    expect(find.byType(Switch), findsNothing);
    expect(find.text('取消修复'), findsOneWidget);
  });

  // 「已框选：归一化 0.400, 0.350 → 0.580, 0.520」原来是直接露给用户的。
  // 「归一化」是我们的术语；用户关心的是框住了多大一块。
  testWidgets('选区提示说像素尺寸，不向用户露归一化坐标', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        // 0.4..0.58 → 0.18 × 960 = 172.8 ≈ 173；0.35..0.52 → 0.17 × 540 = 91.8 ≈ 92
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
      ),
    );
    // 这一页没有滚动容器（内容用 Column + Spacer 撑满），所以不需要
    // `scrollUntilVisible` —— 那反而会以 `Bad state: No element` 崩掉。
    expect(find.text('已框选 173 × 92'), findsOneWidget);
    expect(
      find.textContaining('归一化'),
      findsNothing,
      reason: '这是内部术语，用户看不懂，也不该看到',
    );
  });

  test('selectionLabel 用显示尺寸算，旋转 90° 时宽高不能反', () {
    const landscape = VideoMeta(
      path: '/tmp/a.mp4',
      width: 960,
      height: 540,
      rotation: 0,
      displayWidth: 960,
      displayHeight: 540,
      duration: Duration(seconds: 5),
      hasAudio: true,
      sizeBytes: 1,
    );
    // 竖拍：编码 960×540 + rot=90，用户看到的是 540×960。
    // 若误用 width/height，宽高会正好反过来 —— 用户一眼能看出不对。
    const portrait = VideoMeta(
      path: '/tmp/b.mp4',
      width: 960,
      height: 540,
      rotation: 90,
      displayWidth: 540,
      displayHeight: 960,
      duration: Duration(seconds: 5),
      hasAudio: true,
      sizeBytes: 1,
    );

    expect(
      selectionLabel(const Rect.fromLTRB(0.25, 0.1, 0.75, 0.4), landscape),
      '已框选 480 × 162',
    );
    expect(
      selectionLabel(const Rect.fromLTRB(0.25, 0.1, 0.75, 0.4), portrait),
      '已框选 270 × 288',
      reason: '竖拍视频按显示尺寸算：宽 0.5×540、高 0.3×960',
    );
  });

  test('selectionLabel 尺寸未知时只说「已框选」，不编数字', () {    const unknown = VideoMeta(
      path: '/tmp/c.mp4',
      width: 0,
      height: 0,
      rotation: 0,
      displayWidth: 0,
      displayHeight: 0,
      duration: Duration.zero,
      hasAudio: false,
      sizeBytes: 0,
    );

    expect(selectionLabel(const Rect.fromLTRB(0, 0, 0.5, 0.5), unknown), '已框选');
    // 退化选区（按下就抬手，宽高为 0）也不该显示「0 × 0」
    expect(
      selectionLabel(const Rect.fromLTRB(0.5, 0.5, 0.5, 0.5), unknown),
      '已框选',
    );
  });

  // ---- 「跟随」的取证 ----
  //
  // 原生一直在算 motionTracked / motionShiftPx / keyframeSwitches，Dart 也解析进
  // `VideoRepairResult` 了，但界面从来没显示过。结果是：用户开了「跟随画面」，
  // 修完不知道它到底跟没跟上 —— 一个开关没有反馈，等于让人盲信。

  VideoRepairResult withMotion({
    int tracked = 148,
    int failed = 2,
    double shiftPx = 96.4,
    int keyframes = 2,
  }) {
    return VideoRepairResult(
      outputPath: '/tmp/fixed.mp4',
      width: 960,
      height: 540,
      rotation: 0,
      frames: 150,
      skippedFrames: 0,
      videoBytes: 1397148,
      audioBytes: 161792,
      hasAudio: true,
      maskPixels: 15824,
      sizeBytes: 1562172,
      elapsed: const Duration(milliseconds: 56074),
      motionTracked: tracked,
      motionFailed: failed,
      motionShiftPx: shiftPx,
      keyframeSwitches: keyframes,
    );
  }

  test('motionSummary 说清对齐几帧、位移多少、换了几次关键帧', () {
    expect(
      motionSummary(withMotion()),
      '跟随 148 / 150 帧对齐 · 首末位移 96 px · 换关键帧 2 次',
    );
    // 全部对齐时不写分母，也不写「0 帧退回原位」
    expect(
      motionSummary(withMotion(tracked: 150, failed: 0, shiftPx: 12.6)),
      '跟随 150 帧全部对齐 · 首末位移 13 px · 换关键帧 2 次',
    );
  });

  test('motionSummary 位移是「首末」，不是各帧之和', () {
    // 原生 `cumulativeShiftPx` 的定义是首帧→末帧的模长。文案若写成「累计位移」，
    // 会被读成「一共挪了多少」—— 一个来回抖 300 帧的视频，两者差一个数量级。
    expect(motionSummary(withMotion(shiftPx: 0)), contains('首末位移 0 px'));
    expect(motionSummary(withMotion()), isNot(contains('累计')));
  });

  testWidgets('有跟随数据：结果卡片上真的出现这一行', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        trackMotion: true,
        result: withMotion(),
      ),
    );

    expect(find.textContaining('跟随 148 / 150 帧对齐'), findsOneWidget);
  });

  testWidgets('没开跟随（两计数都是 0）：不显示这一行，免得满屏 0', (tester) async {
    await pumpPage(tester, resultState());

    expect(find.text('修复完成'), findsOneWidget, reason: '结果卡片本身要在');
    expect(
      find.textContaining('跟随'),
      findsNothing,
      reason: '镜头静止的视频没有跟踪数据，露一行「跟随 0 帧」只会让人以为坏了',
    );
  });

  testWidgets('跟踪全失败：这一行更要在（最该知道的消息）', (tester) async {
    await pumpPage(
      tester,
      VideoEditState(
        videoPath: meta.path,
        meta: meta,
        poster: posterBytes,
        posterSize: const Size(960, 540),
        selection: const Rect.fromLTRB(0.4, 0.35, 0.58, 0.52),
        trackMotion: true,
        result: withMotion(tracked: 0, failed: 150, shiftPx: 0, keyframes: 0),
      ),
    );

    expect(
      find.textContaining('跟随 0 / 150 帧对齐'),
      findsOneWidget,
      reason: '一帧都没跟上还显示得跟成功一样，就是在骗人',
    );
  });
}

/// 只用来把状态灌进页面。所有业务方法都继承自真控制器，但测试里不会被调用。
class _FakeController extends VideoEditController {
  _FakeController(this._initial);

  final VideoEditState _initial;

  @override
  VideoEditState build() => _initial;

  /// 换一份状态，模拟「同一页面上又修完一件作品」。
  void swap(VideoEditState next) => state = next;
}
