import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/media/gallery_saver.dart';
import 'package:watermark_remover/core/media/media_channel.dart';
import 'package:watermark_remover/core/media/thumbnail_store.dart';
import 'package:watermark_remover/core/media/video_repairer.dart';
import 'package:watermark_remover/core/processing/processing_error.dart';
import 'package:watermark_remover/features/history/application/history_providers.dart';
import 'package:watermark_remover/features/history/domain/history_item.dart';
import 'package:watermark_remover/features/history/infrastructure/history_store.dart';
import 'package:watermark_remover/features/video_editor/application/video_edit_controller.dart';

/// 视频控制器的主链路。
///
/// 这一页之前只有 **widget 测试**（拿现成的 `VideoEditState` 渲染页面），
/// 控制器本身一条都没有 —— 而状态真正流转的地方是它：探测失败、取消、OOM、保存。
///
/// 之前记的「视频控制器没法单测，因为要先探测成功」是**错的**：
/// `VideoProbe` / `VideoRepairer` 走 `kMediaChannelName`，`getTemporaryDirectory()`
/// 走 path_provider 通道，示例视频走 asset 通道 —— 三条都能 mock，不需要真机和解码器。
/// 模拟原生侧**反向**调用 `onVideoProgress`（两趟化后带 `phase`）。
///
/// 方向是 native → Dart，所以必须走 `handlePlatformMessage`；
/// `setMockMethodCallHandler` 管的是 Dart → native，反着用不会报错，只是永远收不到。
Future<void> emitProgress(
  String taskId,
  String phase,
  int done,
  int total,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        kMediaChannelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onVideoProgress', <String, Object?>{
            'taskId': taskId,
            'phase': phase,
            'done': done,
            'total': total,
          }),
        ),
        (_) {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late List<MethodCall> mediaCalls;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wm_video_ctl_');
    mediaCalls = <MethodCall>[];
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ProviderContainer> makeContainer({
    Future<Object?> Function(MethodCall call)? onRepair,
    PlatformException? probeFailure,
    GallerySaver? saver,
    HistoryStore? historyStore,
    ThumbnailStore? thumbnails,

    /// 取「输出视频首帧」时失败 —— 验证「没有对比图」不该影响「修复成功」的判定
    bool failResultFrame = false,
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );

    messenger.setMockMethodCallHandler(
      const MethodChannel(kMediaChannelName),
      (call) async {
        mediaCalls.add(call);
        switch (call.method) {
          case 'probeVideo':
            if (probeFailure != null) throw probeFailure;
            return <String, Object?>{
              'path': call.arguments['path'],
              'width': 960,
              'height': 540,
              'rotation': 0,
              'displayWidth': 960,
              'displayHeight': 540,
              'durationMs': 5056,
              'hasAudio': true,
              'sizeBytes': 1128375,
            };
          case 'extractVideoFrame':
            // 取「输出视频」的首帧（结果页做对比用）可以被要求失败。
            final target = call.arguments['path'] as String?;
            final isResult = target != null && target.endsWith('fixed.mp4');
            if (failResultFrame && isResult) {
              throw PlatformException(code: 'decode_failed', message: 'decode');
            }
            // 控制器会 `File(framePath).readAsBytes()` —— 必须是**真文件**。
            // 内容按来源区分（修好的首帧填 99、封面帧填 7），否则「缩略图用的是哪一张」
            // 在断言里根本区分不出来。
            final frame = File('${tmp.path}/${isResult ? 'result' : 'poster'}.png')
              ..writeAsBytesSync(List<int>.filled(64, isResult ? 99 : 7));
            return <String, Object?>{
              'framePath': frame.path,
              'width': 960,
              'height': 540,
              'elapsedMs': 12,
            };
          case 'repairVideo':
            if (onRepair != null) return onRepair(call);
            return <String, Object?>{
              'outputPath': '${tmp.path}/fixed.mp4',
              'width': 960,
              'height': 540,
              'rotation': 0,
              'frames': 150,
              'skippedFrames': 0,
              'videoBytes': 1397636,
              'audioBytes': 161792,
              'hasAudio': true,
              'maskPixels': 4321,
              'sizeBytes': 1562660,
              'elapsedMs': 5025,
            };
        }
        return null;
      },
    );

    final c = ProviderContainer(
      overrides: [
        historyStoreProvider.overrideWithValue(
          historyStore ?? MemoryHistoryStore(),
        ),
        initialHistoryProvider.overrideWithValue(const []),
        if (thumbnails != null)
          thumbnailStoreProvider.overrideWithValue(thumbnails),
        if (saver != null) gallerySaverProvider.overrideWithValue(saver),
      ],
    );
    addTearDown(() async {
      // 先给 fire-and-forget 的「写历史」一点时间跑完。
      // 不等的话日志里会冒出 `Cannot use the Ref ... after it has been disposed` ——
      // 那是**测试自己**把容器拆早了，不是产品问题（provider 是 keepAlive 的，
      // 真机上 App 活着它就不会被销毁）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.dispose();
      messenger.setMockMethodCallHandler(
        const MethodChannel(kMediaChannelName),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });
    return c;
  }

  /// 走 `loadSample()`：asset 读得到（测试自带 bundle），落盘后交给 `_adopt` 探测。
  Future<void> loadReady(ProviderContainer c) async {
    await c.read(videoEditControllerProvider.notifier).loadSample();
    expect(
      c.read(videoEditControllerProvider).error,
      isNull,
      reason: '准备步骤不该失败',
    );
    c
        .read(videoEditControllerProvider.notifier)
        .setSelection(const Rect.fromLTWH(0.2, 0.6, 0.4, 0.2));
  }

  test('探测成功 → 元数据、封面、可以框选', () async {
    final c = await makeContainer();
    await loadReady(c);

    final state = c.read(videoEditControllerProvider);
    expect(state.meta?.displayWidth, 960);
    expect(state.meta?.duration, const Duration(milliseconds: 5056));
    expect(state.meta?.hasAudio, isTrue);
    expect(state.poster, isNotNull, reason: '没有封面就没法框选');
    expect(state.canRepair, isTrue);
  });

  test('容器不支持：原生写的中文原因原样到界面，不带异常类型名', () async {
    final c = await makeContainer(
      probeFailure: PlatformException(
        code: 'IO_ERROR',
        message: '打不开这个视频：可能是封装格式系统不支持（AVI / RMVB / WMV 等）。'
            '转成 MP4（H.264 + AAC）再试。',
      ),
    );

    await c.read(videoEditControllerProvider.notifier).loadSample();

    final state = c.read(videoEditControllerProvider);
    expect(state.error, contains('转成 MP4'));
    expect(state.error, isNot(contains('PlatformException')));
    expect(state.busy, isFalse, reason: '失败后按钮要能再点');
  });

  test('用户取消：显示「已取消」，不是英文错误', () async {
    final c = await makeContainer(
      onRepair: (call) async =>
          throw PlatformException(code: 'cancelled', message: 'cancelled'),
    );
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();

    final state = c.read(videoEditControllerProvider);
    expect(state.error, '已取消');
    expect(state.processing, isFalse, reason: '取消后不能永远卡在「修复中」');
    expect(state.result, isNull);
  });

  test('内存不够：给中文话术，不把原生英文糊到界面', () async {
    final c = await makeContainer(
      onRepair: (call) async =>
          throw PlatformException(code: 'out_of_memory', message: null),
    );
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();

    final state = c.read(videoEditControllerProvider);
    expect(state.error, contains('内存'));
    expect(state.processing, isFalse);
    expect(state.canRepair, isTrue, reason: '失败要能重来一次');
  });

  test('成功：结果进状态，帧数/音轨来自返回的那一份', () async {
    final c = await makeContainer();
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();

    final state = c.read(videoEditControllerProvider);
    expect(state.error, isNull);
    expect(state.result?.frames, 150);
    expect(state.result?.hasAudio, isTrue);
    expect(state.canSave, isTrue, reason: '结果出来了就该能保存');
  });

  test('选区与开关一路传到原生（归一化坐标）', () async {
    final c = await makeContainer();
    await loadReady(c);
    c.read(videoEditControllerProvider.notifier).setTrackMotion(true);

    await c.read(videoEditControllerProvider.notifier).startRepair(radius: 6);

    final repair = mediaCalls.firstWhere((call) => call.method == 'repairVideo');
    final args = repair.arguments as Map;
    expect(args['trackMotion'], isTrue);
    expect(args['radius'], 6);
    // 选区是**归一化**坐标：换分辨率也不会框歪
    expect(args['left'], closeTo(0.2, 1e-6));
    expect(args['top'], closeTo(0.6, 1e-6));
    expect(args['right'], closeTo(0.6, 1e-6));
    expect(args['bottom'], closeTo(0.8, 1e-6));
  });

  test('取消按钮：taskId 真的发给原生，完成后 taskId 归位', () async {
    // 让 repairVideo 挂着不返回 —— 模拟「正在修复」
    final gate = Completer<Object?>();
    final c = await makeContainer(onRepair: (call) => gate.future);
    await loadReady(c);

    final running = c.read(videoEditControllerProvider.notifier).startRepair();
    final taskId = c.read(videoEditControllerProvider).taskId;
    expect(taskId, isNotNull, reason: '没有 taskId，取消就发不出去');

    await c.read(videoEditControllerProvider.notifier).cancelRepair();
    final cancel = mediaCalls.firstWhere((call) => call.method == 'cancel');
    expect((cancel.arguments as Map)['taskId'], taskId);

    gate.complete(<String, Object?>{'frames': 0});
    await running;
    expect(c.read(videoEditControllerProvider).taskId, isNull);
  });

  /// 修完之后要取**输出视频的首帧** —— 结果页的对比分屏靠它。
  ///
  /// 首帧和封面帧是同一个时间点，所以能像素级对比；不取的话结果页只能继续摆
  /// 带水印的封面帧，用户会以为没修干净。
  test('跟随开启：两趟进度各走各的，第二趟不清空第一趟', () async {
    late ProviderContainer c;
    var motionAtFirst = -1.0;
    var phaseAtFirst = VideoRepairPhase.idle;
    var finishedAtFirst = false;
    var repairAtSecond = -1.0;
    var phaseAtSecond = VideoRepairPhase.idle;
    var motionKept = -1.0;
    var repairWasEmptyDuringMotion = false;

    c = await makeContainer(
      onRepair: (call) async {
        final taskId = call.arguments['taskId'] as String;

        // 第一趟：只报「分析镜头运动」，此时「逐帧修复」还没开始
        await emitProgress(taskId, 'motion', 60, 60);
        var s = c.read(videoEditControllerProvider);
        motionAtFirst = s.motionFraction ?? -1;
        phaseAtFirst = s.phase;
        finishedAtFirst = s.motionFinished;
        repairWasEmptyDuringMotion = s.progressFraction == null;

        // 第二趟：修复进度上岗，第一趟的进度必须还在（不能被冲成 0/0）
        await emitProgress(taskId, 'repair', 30, 150);
        s = c.read(videoEditControllerProvider);
        repairAtSecond = s.progressFraction ?? -1;
        phaseAtSecond = s.phase;
        motionKept = s.motionFraction ?? -1;

        return <String, Object?>{
          'outputPath': '${tmp.path}/fixed.mp4',
          'width': 960,
          'height': 540,
          'rotation': 0,
          'frames': 150,
          'skippedFrames': 0,
          'videoBytes': 1397636,
          'audioBytes': 161792,
          'hasAudio': true,
          'maskPixels': 4321,
          'sizeBytes': 1562660,
          'elapsedMs': 5025,
        };
      },
    );
    await loadReady(c);
    c.read(videoEditControllerProvider.notifier).setTrackMotion(true);
    await c.read(videoEditControllerProvider.notifier).startRepair();

    expect(motionAtFirst, closeTo(1.0, 1e-9), reason: '60/60 该走满');
    expect(phaseAtFirst, VideoRepairPhase.motion);
    expect(finishedAtFirst, isTrue);
    expect(
      repairWasEmptyDuringMotion,
      isTrue,
      reason: '第一趟还没跑完，第二趟不该显示任何进度（否则是假进度）',
    );
    expect(repairAtSecond, closeTo(0.2, 1e-9), reason: '30/150 该是 20%');
    expect(phaseAtSecond, VideoRepairPhase.repair);
    expect(
      motionKept,
      closeTo(1.0, 1e-9),
      reason: '第二趟把第一趟的完成状态冲掉了 —— 用户会以为又从头跑了一遍',
    );
  });

  test('修完会取输出视频首帧，供对比分屏用', () async {
    final c = await makeContainer();
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();
    // 抽帧已经改成 await（跟着 `startRepair` 一起结束），这里不用再等
    // —— 留一点余量只是为了让 fire-and-forget 的写历史跑完。
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final state = c.read(videoEditControllerProvider);
    expect(state.resultFrame, isNotNull);
    expect(state.resultFrameSize, const Size(960, 540));
    expect(
      mediaCalls.where((call) => call.method == 'extractVideoFrame').length,
      2,
      reason: '一次取封面帧、一次取输出首帧',
    );
  });

  test('首帧取不到：修复仍算成功，只是没有对比图', () async {    final c = await makeContainer(failResultFrame: true);
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final state = c.read(videoEditControllerProvider);
    expect(state.result, isNotNull, reason: '抽帧失败不等于修复失败');
    expect(state.error, isNull, reason: '不该给用户报一个他无法处理的错');
    expect(state.resultFrame, isNull);
    expect(state.canSave, isTrue, reason: '结果还是要能存进相册');
  });

  test('保存成功：拿到 content:// 就不再重存（相册里不该有两份）', () async {
    final saver = _CapturingSaver();
    final c = await makeContainer(saver: saver);
    await loadReady(c);
    await c.read(videoEditControllerProvider.notifier).startRepair();

    await c.read(videoEditControllerProvider.notifier).saveToGallery();
    expect(saver.videoCalls, 1);
    expect(
      c.read(videoEditControllerProvider).savedUri,
      startsWith('content://media/'),
    );

    await c.read(videoEditControllerProvider.notifier).saveToGallery();
    expect(saver.videoCalls, 1, reason: '连点会让相册里出现两份');
  });

  /// Android 9 及以下没有存储权限时，原生回 `permission_denied`。
  /// 这条是**唯一一个用户当场能自己解决**的保存失败，文案必须指路，
  /// 不能落到通用的「保存失败，检查存储空间」。
  test('保存遇到 permission_denied：文案要指路，不能只说保存失败', () async {
    final c = await makeContainer(saver: _DeniedSaver());
    await loadReady(c);
    await c.read(videoEditControllerProvider.notifier).startRepair();

    await c.read(videoEditControllerProvider.notifier).saveToGallery();

    final state = c.read(videoEditControllerProvider);
    expect(state.savedUri, isNull);
    final msg = state.saveError ?? '';
    expect(msg, contains('存储权限'), reason: '得让用户知道是权限问题');
    expect(msg, contains('设置'), reason: '得告诉他去哪儿开');
    expect(msg, isNot(contains('存储空间')), reason: '别提存储空间，会把人带偏');
  });

  /// 历史写盘失败时，刚生成的那张缩略图必须删掉。
  ///
  /// 图片页的 `_record` 早就有这一步（catch 里 remove 掉 orphan），视频这边漏了 ——
  /// 又一次「同类逻辑只改一处」。这条用例把两侧拉平。
  test('历史写盘失败：缩略图不留在盘上', () async {
    final thumbs = _SpyThumbnailStore();
    final c = await makeContainer(
      historyStore: _ThrowingHistoryStore(),
      thumbnails: thumbs,
    );
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();
    // 写历史是 fire-and-forget，给它几轮事件循环
    await Future<void>.delayed(const Duration(milliseconds: 80));

    // 先确立前提：这张图真生成过。否则下面「删了」是因为压根没生成，用例空转。
    expect(thumbs.removed, hasLength(1), reason: '生成过一次，就该被删一次');
    expect(thumbs.removed.single, startsWith('/fake/thumbs/'));
  });

  /// 缩略图要取**修好后的首帧**。
  ///
  /// 原来用修复前的封面帧（省一次解码），结果历史列表里图片记录是干净的、
  /// 视频记录还挂着水印，两条并列看着就像「视频那条没修干净」。
  /// 首帧本来就要为对比分屏取一次，改用它等于白捡。
  test('历史缩略图用修好后的首帧，不是带水印的封面帧', () async {
    final thumbs = _SpyThumbnailStore();
    final c = await makeContainer(thumbnails: thumbs);
    await loadReady(c);

    await c.read(videoEditControllerProvider.notifier).startRepair();
    // 写历史是 fire-and-forget，给它几轮事件循环
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(thumbs.saved, hasLength(1), reason: '一条记录一张缩略图');
    expect(
      thumbs.saved.single.first,
      99,
      reason: '拿到的是封面帧（7）说明历史里还会显示水印',
    );
  });
}

/// 只数调用次数，不碰真通道。
class _CapturingSaver extends GallerySaver {
  int videoCalls = 0;

  @override
  Future<String> saveVideo({
    required String sourcePath,
    String? displayName,
  }) async {
    videoCalls++;
    return 'content://media/external_primary/video/media/42';
  }
}

/// 写盘永远失败 —— 模拟磁盘满 / 被系统回收。
class _ThrowingHistoryStore implements HistoryStore {
  @override
  Future<List<HistoryItem>> read() async => const <HistoryItem>[];

  @override
  Future<void> write(List<HistoryItem> items) async =>
      throw const FileSystemException('disk full');
}

/// 不碰文件系统：save 给一个假的稳定路径，remove 只记下来。
///
/// 真实 `ThumbnailStore.save` 会走 `dart:ui` 解码，喂进去的假字节解不出来 → 返回 null，
/// 于是「有没有生成过」都无从判断，用例会空转。
class _SpyThumbnailStore extends ThumbnailStore {
  final List<String?> removed = <String?>[];

  /// 每次 `save(id, source)` 收到的原图字节 —— 用来断言「缩略图取自哪一张」。
  final List<Uint8List> saved = <Uint8List>[];

  @override
  Future<String?> save(String id, Uint8List source) async {
    saved.add(source);
    return '/fake/thumbs/$id.png';
  }

  @override
  Future<void> remove(String? path) async => removed.add(path);
}

/// 模拟 Android ≤ 9 没给存储权限：原生回 `permission_denied`。
class _DeniedSaver extends GallerySaver {
  @override
  Future<String> saveVideo({
    required String sourcePath,
    String? displayName,
  }) async {
    // **不带 detail**：要走 userMessage 那条兜底，
    // 这样用例才真的在验「错误码 → 用户话术」这一层映射
    throw const ProcessingException(ProcessingErrorCode.permissionDenied);
  }
}
