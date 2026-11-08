import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/video_previewer.dart';
import 'package:watermark_remover/core/theme/app_theme.dart';
import 'package:watermark_remover/core/widgets/video_preview_dialog.dart';

/// 预览播放器的外壳行为。
///
/// 只测**不需要真解码器**的部分：失败话术、纹理挂载、关闭、尺寸。
/// 真正的解码由原生 `MediaPlayer` 负责，这里用假 [VideoPreviewer] 替掉通道，
/// 测的是「我们怎么用它」；能不能解这个 mp4 只有真机能答。
void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required _FakePreviewer previewer,
    String path = '/data/tmp/fixed_1.mp4',
    VoidCallback? onClosed,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [videoPreviewerProvider.overrideWithValue(previewer)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    await VideoPreviewDialog.show(
                      context,
                      path,
                      title: '预览修复效果',
                    );
                    onClosed?.call();
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(); // 弹出对话框
    await tester.pump(const Duration(milliseconds: 60)); // 让 open() 的 await 回来
  }

  /// 关掉对话框并让 periodic 轮询停掉，否则测试结束会报「Timer still pending」
  Future<void> closeDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('preview-close')));
    // 退场动画走完 → State dispose → 轮询 timer 被 cancel，这里才能收敛
    await tester.pumpAndSettle();
  }

  testWidgets('打开成功：挂上纹理、控制条在、对话框有实际高度', (tester) async {
    final previewer = _FakePreviewer();
    await pumpDialog(tester, previewer: previewer);

    expect(previewer.openedPath, '/data/tmp/fixed_1.mp4');
    // 画面是原生纹理，不是 Image —— 这才叫「真的在播」，不是贴一张首帧
    final texture = tester.widget<Texture>(
      find.byKey(const ValueKey('preview-texture')),
    );
    expect(texture.textureId, 7);
    expect(find.byKey(const ValueKey('preview-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-seek')), findsOneWidget);
    expect(find.text('00:05'), findsOneWidget, reason: '总时长该显示出来');

    // 第一版把内容塞进 `Column(mainAxisSize.min)` 的 Flexible 里，
    // 真机上对话框只剩一条细边，用户看到的是「点了没反应」。
    final dialog = tester.getRect(find.byType(Dialog));
    expect(dialog.height, greaterThan(150), reason: '对话框塌成一条了');
    expect(dialog.width, greaterThan(200), reason: '对话框窄到看不出内容');

    await closeDialog(tester);
    expect(previewer.closed, isTrue, reason: '关掉对话框必须释放原生播放器');
  });

  testWidgets('横屏矮视口：画面保持比例，控制条不被挤出屏幕', (tester) async {
    // 真机 1080×2340 转横屏后的逻辑尺寸。回归的真机缺陷：
    // 画面被拉成 3.46:1（正常 1.78），进度条与暂停按钮整块被挤出对话框底部。
    await tester.binding.setSurfaceSize(const Size(780, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final previewer = _FakePreviewer();
    await pumpDialog(tester, previewer: previewer);
    // 对话框有入场动画（从底部滑上来），60ms 时还没落位，量出来的坐标会偏。
    // 不能用 pumpAndSettle：位置轮询是 periodic timer，永远 settle 不了。
    await tester.pump(const Duration(milliseconds: 400));

    final stage = tester.getRect(
      find.byKey(const ValueKey('preview-texture')),
    );
    expect(stage.width / stage.height, closeTo(960 / 540, 0.05),
        reason: '画面必须按原比例显示，不能被 Column 的紧宽度拉变形');
    expect(stage.bottom, lessThanOrEqualTo(360),
        reason: '画面不许超出屏幕');
    // 宽视口下控制条在右侧，画面应该吃掉横向空间。
    // 竖排那版只能缩到约 203×114（780dp 宽的面板大半空着），这里必须明显更宽。
    expect(stage.width, greaterThan(300),
        reason: '横屏要横着用：画面宽度应该远超竖排那版的 ~203');
    expect(stage.height, lessThanOrEqualTo(360 - 80),
        reason: '画面不许超过对话框可用高度');

    // 控制条必须落在**对话框面板之内**。
    // 只比屏幕高度是不够的：内容溢出时被滚动视口裁掉，控件几何位置仍在屏幕里，
    // 断言照样绿 —— 那正是「看不见但测得过」的假通过。
    final panel = tester.getRect(find.byKey(const ValueKey('preview-panel')));
    for (final key in ['preview-toggle', 'preview-seek']) {
      final r = tester.getRect(find.byKey(ValueKey(key)));
      expect(r.top, greaterThanOrEqualTo(panel.top), reason: '$key 跑到面板上方了');
      expect(r.bottom, lessThanOrEqualTo(panel.bottom),
          reason: '$key 被挤出面板底部（滚动视口外 = 看不到）');
    }

    await closeDialog(tester);
  });

  testWidgets('打不开：说人话，给出退路，不崩', (tester) async {
    final previewer = _FakePreviewer(fail: true);
    await pumpDialog(tester, previewer: previewer);

    expect(find.text('这段视频暂时播不了'), findsOneWidget);
    // 这条提示是给用户的退路：播不了不等于文件坏了
    expect(find.textContaining('保存到相册'), findsOneWidget);
    // 没准备好就不该出现播放控制 —— 点了也没用
    expect(find.byKey(const ValueKey('preview-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('preview-texture')), findsNothing);

    final dialog = tester.getRect(find.byType(Dialog));
    expect(dialog.height, greaterThan(80), reason: '对话框塌成一条了');

    await tester.tap(find.byKey(const ValueKey('preview-close')));
    await tester.pumpAndSettle();
    expect(find.text('预览修复效果'), findsNothing);
  });

  testWidgets('底板不透明：背后页面的按钮不许透进对话框', (tester) async {
    final previewer = _FakePreviewer();
    await pumpDialog(tester, previewer: previewer);

    // 第一版把内容直接放在透明的 Dialog 上，真机上背后那页的
    // 「修复前 / 对比 / 修复后」「保存到相册」从标题跟控制条之间透出来
    // （B6/C5 截图）。这里的断言盯的是**不透明度**，不是「画得像不像」。
    final panel = tester.widget<Container>(
      find.byKey(const ValueKey('preview-panel')),
    );
    final decoration = panel.decoration! as BoxDecoration;
    expect(
      decoration.color!.a,
      1.0,
      reason: '底板半透明，背后页面就会透上来',
    );

    // 画面与标题都得落在这块板子里，否则板子白加
    final panelRect = tester.getRect(find.byKey(const ValueKey('preview-panel')));
    for (final key in const ['preview-texture', 'preview-toggle', 'preview-close']) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(
        panelRect.contains(rect.topLeft) && panelRect.contains(rect.bottomRight),
        isTrue,
        reason: '「$key」跑到板子外面了',
      );
    }

    await closeDialog(tester);
  });

  testWidgets('点暂停：图标切到播放，原生收到 pause', (tester) async {
    final previewer = _FakePreviewer();
    await pumpDialog(tester, previewer: previewer);

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(previewer.pauses, 1);
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);

    await closeDialog(tester);
  });
}

class _FakePreviewer implements VideoPreviewer {
  _FakePreviewer({this.fail = false});

  final bool fail;
  String? openedPath;
  bool closed = false;
  int pauses = 0;

  @override
  Future<VideoPreviewHandle> open(String path) async {
    openedPath = path;
    if (fail) {
      throw const VideoPreviewException('preview_failed', 'decode init failed');
    }
    return const VideoPreviewHandle(
      textureId: 7,
      width: 960,
      height: 540,
      duration: Duration(seconds: 5),
    );
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<Duration> position() async => Duration.zero;

  @override
  Future<void> close() async => closed = true;
}
