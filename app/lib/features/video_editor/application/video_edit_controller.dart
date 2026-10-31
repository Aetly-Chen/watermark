import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/format/sizes.dart';
import '../../../core/media/gallery_saver.dart';
import '../../../core/media/thumbnail_store.dart';
import '../../../core/media/video_probe.dart';
import '../../../core/media/video_repairer.dart';
import '../../../core/processing/processing_error.dart';
import '../../history/application/history_providers.dart';
import '../../history/domain/history_format.dart';
import '../../history/domain/history_item.dart';

part 'video_edit_controller.g.dart';

/// 视频编辑页状态：选视频 → 探测元数据 → 抽封面帧 → 在封面上框选 → 逐帧修复。
///
/// 为什么不在这里存解码器或帧缓存：视频处理的资源生命周期（Codec / Extractor）
/// 比页面长，放状态里必然泄漏。控制器只持有**可重建的东西**（路径、元数据、封面字节）。
@immutable
class VideoEditState {
  const VideoEditState({
    this.videoPath,
    this.meta,
    this.poster,
    this.posterSize,
    this.selection,
    this.busy = false,
    this.error,
    this.processing = false,
    this.progressDone = 0,
    this.progressTotal = 0,
    this.phase = VideoRepairPhase.idle,
    this.motionDone = 0,
    this.motionTotal = 0,
    this.motionFinished = false,
    this.result,
    this.resultFrame,
    this.resultFrameSize,
    this.taskId,
    this.trackMotion = false,
    this.saving = false,
    this.savedUri,
    this.saveError,
  });

  final String? videoPath;
  final VideoMeta? meta;

  /// 封面帧 PNG 字节。框选就在这张图上做。
  final Uint8List? poster;

  /// 封面帧的真实像素尺寸（可能小于视频：探测时按最长边 1080 缩过）
  final Size? posterSize;

  /// 归一化选区（0..1，相对**封面帧**）
  final Rect? selection;

  final bool busy;
  final String? error;

  /// 视频修复进行中（与 [busy] 分开：busy 是选片/探测，processing 是转码）
  final bool processing;
  /// 第二趟（逐帧修复）的进度
  final int progressDone;
  final int progressTotal;

  /// 当前跑到哪一趟
  final VideoRepairPhase phase;

  /// 第一趟（分析镜头运动）的进度。关掉跟随时全程是 0/0。
  final int motionDone;
  final int motionTotal;
  final bool motionFinished;
  final VideoRepairResult? result;

  /// 修好之后**输出视频的首帧**（PNG 字节）。
  ///
  /// 和 [poster]（修复前的封面帧）是**同一个时间点**，所以两张图可以直接像素级对比 ——
  /// 这就是视频结果页的「对比」分屏。修完却只显示带水印的封面帧，用户会以为没修干净。
  ///
  /// 取不到就是 null：那只是没有对比图，不该让一次成功的修复显示成失败。
  final Uint8List? resultFrame;
  final Size? resultFrameSize;

  /// 进行中任务的 id，取消时要用
  final String? taskId;

  /// 是否让 Mask 跟着画面走（原型里的「静止 / 跟随」开关）。
  ///
  /// 默认 **false**：真实手持/变焦素材上的跟随可信度还没建立（实测逐帧累加与
  /// 首末帧直接估计相差 38.5px，两者谁准判不了）。这是「可以开，但不替你开」。
  final bool trackMotion;

  /// 正在写相册
  final bool saving;

  /// 已存进相册的 MediaStore URI
  final String? savedUri;
  final String? saveError;

  bool get hasVideo => poster != null && meta != null;
  bool get canSave => result != null && !saving && savedUri == null;
  bool get canSelect => hasVideo && !busy && !processing;
  bool get canRepair => selection != null && meta != null && !processing && !busy;

  /// 进度 0..1。总数未知时返回 null —— 不拿假数字喂进度条。
  double? get progressFraction {
    if (progressTotal <= 0) return null;
    return (progressDone / progressTotal).clamp(0.0, 1.0);
  }

  /// 第一趟的进度 0..1。没有这一趟（关掉跟随）时返回 null。
  double? get motionFraction {
    if (!trackMotion || motionTotal <= 0) return null;
    return (motionDone / motionTotal).clamp(0.0, 1.0);
  }

  VideoEditState copyWith({
    String? videoPath,
    VideoMeta? meta,
    Uint8List? poster,
    Size? posterSize,
    Rect? selection,
    bool? busy,
    String? error,
    bool? processing,
    int? progressDone,
    int? progressTotal,
    VideoRepairPhase? phase,
    int? motionDone,
    int? motionTotal,
    bool? motionFinished,
    VideoRepairResult? result,
    Uint8List? resultFrame,
    Size? resultFrameSize,
    String? taskId,
    bool? trackMotion,
    bool? saving,
    String? savedUri,
    String? saveError,
    bool clearSelection = false,
    bool clearError = false,
    bool clearResult = false,
    bool clearTask = false,
    bool clearSave = false,
  }) {
    return VideoEditState(
      videoPath: videoPath ?? this.videoPath,
      meta: meta ?? this.meta,
      poster: poster ?? this.poster,
      posterSize: posterSize ?? this.posterSize,
      selection: clearSelection ? null : (selection ?? this.selection),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      processing: processing ?? this.processing,
      progressDone: progressDone ?? this.progressDone,
      progressTotal: progressTotal ?? this.progressTotal,
      phase: phase ?? this.phase,
      motionDone: motionDone ?? this.motionDone,
      motionTotal: motionTotal ?? this.motionTotal,
      motionFinished: motionFinished ?? this.motionFinished,
      result: clearResult ? null : (result ?? this.result),
      // 首帧和 result 是一体的：result 清掉时它必须一起清，
      // 否则下一次修复会先闪一下上一次的对比图（两段素材对不上）。
      resultFrame: clearResult ? null : (resultFrame ?? this.resultFrame),
      resultFrameSize: clearResult
          ? null
          : (resultFrameSize ?? this.resultFrameSize),
      taskId: clearTask ? null : (taskId ?? this.taskId),
      trackMotion: trackMotion ?? this.trackMotion,
      saving: saving ?? this.saving,
      savedUri: clearSave ? null : (savedUri ?? this.savedUri),
      saveError: clearSave ? null : (saveError ?? this.saveError),
    );
  }
}

@Riverpod(keepAlive: true)
class VideoEditController extends _$VideoEditController {
  /// 内置示例视频（MDN flower.mp4，CC0）。真机没有相册视频时用它跑通链路。
  static const String sampleAsset = 'assets/samples/sample.mp4';

  @override
  VideoEditState build() => const VideoEditState();

  Future<void> pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      await _adopt(picked.path);
    } on PlatformException catch (error) {
      // 同图片页：message 是英文 code，不能拼进用户文案。
      debugPrint('[video] 选择器失败：${error.code} ${error.message}');
      state = state.copyWith(
        error: '打不开相册。检查一下系统里的相册/照片权限，再点一次。',
      );
    } on Object catch (error) {
      // 视频页这里原来**只有** PlatformException 一条分支：
      // 选完视频后 `_adopt` 里的其它失败（文件被删、探测超时）会变成
      // 一条 uncaught async error —— 界面什么都不发生。
      debugPrint('[video] 打开失败：$error');
      state = state.copyWith(
        busy: false,
        error: '打不开这个视频。换成相册里的 MP4 再试一次。',
      );
    }
  }

  /// 调试入口：把打包进 assets 的示例视频落到临时目录再探测。
  ///
  /// 必须落盘 —— `MediaMetadataRetriever.setDataSource` 只吃文件路径或 fd，
  /// 不能直接喂内存字节。
  Future<void> loadSample() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final data = await rootBundle.load(sampleAsset);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sample_video.mp4');
      if (!file.existsSync() || file.lengthSync() != data.lengthInBytes) {
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      await _adopt(file.path, markBusy: false);
    } catch (error) {
      // 别用 `$error`：这里可能是 "Unable to load asset" 这类英文，
      // detail 现在会直接显示给用户（见 ProcessingException.message）。
      debugPrint('[video] 示例视频加载失败：$error');
      state = state.copyWith(
        busy: false,
        error: '示例视频加载失败。改用「从相册选择」试试。',
      );
    }
  }

  Future<void> _adopt(String path, {bool markBusy = true}) async {
    if (markBusy) state = state.copyWith(busy: true, clearError: true);
    try {
      final probe = ref.read(videoProbeProvider);
      final meta = await probe.probe(path);
      final dir = await getTemporaryDirectory();
      final frame = await probe.extractFrame(
        path: path,
        outputPath: '${dir.path}/poster_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      final bytes = await File(frame.path).readAsBytes();

      // 封面尺寸和视频编码尺寸可能不同（探测时按最长边缩过）。
      // 所以 Mask 一律用**归一化坐标**表达 —— 处理时按真实帧尺寸再乘回去，
      // 这就是 MaskPlan 坚持用 0..1 而不是像素的原因。
      state = VideoEditState(
        videoPath: path,
        meta: meta,
        poster: bytes,
        posterSize: Size(frame.width.toDouble(), frame.height.toDouble()),
      );
    } on ProcessingException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
    } on PlatformException catch (error) {
      // 原生侧已经把人话写进 message（见 VideoProbe.openRetriever），
      // 这里别再用 `$error` —— 那会渲染成
      // `PlatformException(IO_ERROR, 打不开这个视频：…, null, null)`，
      // 用户看到的是一串括号和 null。
      state = state.copyWith(busy: false, error: error.message ?? '读取视频失败');
    } catch (error) {
      debugPrint('[video] 读取失败：$error');
      state = state.copyWith(
        busy: false,
        error: '读取视频失败。换一个视频试试，或把它转成 MP4（H.264 + AAC）。',
      );
    }
  }

  void setSelection(Rect? normalized) {
    state = state.copyWith(selection: normalized, clearError: true, clearResult: true);
  }

  void reset() {
    state = state.copyWith(clearSelection: true, clearError: true, clearResult: true);
  }

  /// 「静止 / 跟随」开关。转码中不允许改 —— 改的是下一次修复的行为，
  /// 让它在转码中可点只会让人以为改了当前这次。
  void setTrackMotion(bool value) {
    if (state.processing) return;
    state = state.copyWith(trackMotion: value, clearResult: true);
  }

  /// 逐帧修复。`trackMotion` 打开时逐帧估计全局运动、把 Mask 推着走。
  ///
  /// 用 `mutations` 之外的手动赋值（这里没有用 AsyncNotifier），所以要在 finally 里
  /// 保证 processing 一定归位 —— 否则页面会永远卡在「修复中」。
  Future<void> startRepair({int radius = 4}) async {
    final selection = state.selection;
    final videoPath = state.videoPath;
    if (selection == null || videoPath == null || state.processing) return;

    final taskId = 'task-${DateTime.now().microsecondsSinceEpoch}';
    state = state.copyWith(
      processing: true,
      progressDone: 0,
      progressTotal: 0,
      phase: VideoRepairPhase.idle,
      motionDone: 0,
      motionTotal: 0,
      motionFinished: false,
      taskId: taskId,
      clearError: true,
      clearResult: true,
      clearSave: true,
    );

    try {
      final dir = await getTemporaryDirectory();
      final outputPath =
          '${dir.path}/fixed_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final result = await ref
          .read(videoRepairerProvider)
          .repair(
            inputPath: videoPath,
            outputPath: outputPath,
            selection: selection,
            radius: radius,
            trackMotion: state.trackMotion,
            taskId: taskId,
            onProgress: (phase, done, total) {
              if (state.taskId != taskId) return;
              // 两趟各自的进度分开存：第一趟跑完不能把进度条归零，
              // 页面要能同时显示「分析已完成」和「修复进行到哪」。
              state = switch (phase) {
                VideoRepairPhase.motion => state.copyWith(
                  phase: VideoRepairPhase.motion,
                  motionDone: done,
                  motionTotal: total,
                  motionFinished: total > 0 && done >= total,
                ),
                _ => state.copyWith(
                  phase: VideoRepairPhase.repair,
                  progressDone: done,
                  progressTotal: total,
                ),
              };
            },
          );
      state = state.copyWith(processing: false, result: result, clearTask: true);
      // 结果页的对比分屏要用「修好之后的第一帧」。抽帧比修复便宜得多（几十毫秒），
      // 但要 await：丢在后台跑会让文件 IO 的生命周期越过页面/测试的生命周期，
      // Windows 上 tearDown 删临时目录会撞「另一个程序正在使用此文件」（实测踩过）。
      await _loadResultFrame(result.outputPath);
      // 写历史排在取首帧之后：缩略图要用**修好的那张**（见 `_record`）。
      _recordSuccess(result);
    } on ProcessingException catch (error) {
      // 取消不算错误：用户主动停的，提示一句就够
      final message = error.code == ProcessingErrorCode.cancelled
          ? '已取消'
          : error.message;
      state = state.copyWith(processing: false, error: message, clearTask: true);
    } catch (error) {
      debugPrint('[video] 修复失败：$error');
      state = state.copyWith(
        processing: false,
        error: '视频修复失败。可以缩短片段或换一个视频；内存不够时大视频也会失败。',
        clearTask: true,
      );
    }
  }

  /// 取输出视频的**首帧**，给结果页做修复前后对比。
  ///
  /// 用现成的 `extractVideoFrame` 通道，不走播放器 —— 对比分屏要的是一张静态图，
  /// 为了它去启解码器只会多一次生命周期要管。整段播放是另一个入口
  /// （结果页的「预览效果」，见 `core/widgets/video_preview_dialog.dart`）。
  ///
  /// 首帧和封面帧是**同一个时间点**，所以两张图能直接像素级对比。
  /// 取失败只是没有对比图，不打用户可见错误：修复本身是成功的。
  Future<void> _loadResultFrame(String outputPath) async {
    try {
      final dir = await getTemporaryDirectory();
      final frame = await ref
          .read(videoProbeProvider)
          .extractFrame(
            path: outputPath,
            outputPath:
                '${dir.path}/result_${DateTime.now().millisecondsSinceEpoch}.png',
          )
          // 原生抽帧理论上几十毫秒。真卡住时宁可没有对比图，也别让
          // 「修完了」这个状态一直挂在 await 后面（页面上的「保存」会迟迟不出现）。
          .timeout(const Duration(seconds: 5));
      final bytes = await File(frame.path).readAsBytes();
      // provider 已被销毁（用户退出页面）：ref 不能再读，state 也不该再动。
      if (!ref.mounted) return;
      // 期间可能又修了一次：那这张就不是当前结果的首帧，丢掉。
      if (state.result?.outputPath != outputPath) return;
      state = state.copyWith(
        resultFrame: bytes,
        resultFrameSize: Size(frame.width.toDouble(), frame.height.toDouble()),
      );
    } on Object catch (error) {
      debugPrint('[video] 结果首帧提取失败（只是没有对比图）：$error');
    }
  }

  /// 把修好的视频写进相册（`Movies/水印工坊`）。
  ///
  /// 结果文件在临时目录，系统随时可能回收 —— 不导出等于这次修复白做。
  /// 和修复分开是同一个理由：修复失败该重试，保存失败该让用户看存储。
  Future<void> saveToGallery() async {
    final path = state.result?.outputPath;
    if (path == null || state.saving || state.savedUri != null) return;

    state = state.copyWith(saving: true, clearSave: true);
    try {
      final stamp = DateTime.now();
      final name =
          '水印工坊_${stamp.year}'
          '${stamp.month.toString().padLeft(2, '0')}'
          '${stamp.day.toString().padLeft(2, '0')}_'
          '${stamp.hour.toString().padLeft(2, '0')}'
          '${stamp.minute.toString().padLeft(2, '0')}'
          '${stamp.second.toString().padLeft(2, '0')}.mp4';

      final uri = await ref
          .read(gallerySaverProvider)
          .saveVideo(sourcePath: path, displayName: name);
      state = state.copyWith(saving: false, savedUri: uri);
    } on ProcessingException catch (error) {
      state = state.copyWith(saving: false, saveError: error.message);
    } catch (error) {
      // 保存链路最常见的是 `FileSystemException` / `SecurityException` 走通道过来的
      // `PlatformException`；原文是英文 + 路径，只进日志。
      debugPrint('[video] 保存失败：$error');
      state = state.copyWith(
        saving: false,
        saveError: '保存失败。检查一下手机存储空间，或稍后再试。',
      );
    }
  }

  /// 写一条真实历史。刻意**不 await**：历史写盘失败不该把一次成功的修复变成失败。
  void _recordSuccess(VideoRepairResult result) {
    unawaited(_record(result));
    // result 目前只用来确认成功；帧数等信息留给结果卡展示。
    debugPrint('[history] 记录视频 ${result.outputPath.split(RegExp(r'[/\\]')).last}');
  }

  Future<void> _record(VideoRepairResult result) async {
    final now = DateTime.now();
    final id = 'v-${now.microsecondsSinceEpoch}';
    final meta = state.meta;
    final path = state.videoPath;
    final title = path == null
        ? '视频'
        : path.split(RegExp(r'[/\\]')).last;

    final parts = <String>[];
    if (meta != null) {
      parts.add('${meta.displayWidth} × ${meta.displayHeight}');
      parts.add(formatHistoryDuration(meta.duration));
      parts.add(formatBytes(meta.sizeBytes));
    }

    // 缩略图用**修好后的首帧**，取不到才退回修复前的封面帧。
    //
    // 原来一直用封面帧，理由是「它已经在内存里，不用再解一次码」—— 但那样历史列表里
    // 图片记录是干净的、视频记录还挂着水印，两条并列看着就像「视频那条没修干净」。
    // 现在首帧本来就要为对比分屏取一次（`_loadResultFrame`），这里等于白捡。
    String? thumbPath;
    final preview = state.resultFrame ?? state.poster;
    if (preview != null) {
      try {
        thumbPath = await ref.read(thumbnailStoreProvider).save(id, preview);
      } on Object catch (error) {
        debugPrint('[history] 缩略图生成失败：$error');
      }
    }

    try {
      await ref
          .read(historyItemsProvider.notifier)
          .add(
            HistoryItem(
              id: id,
              title: title,
              kind: HistoryKind.video,
              status: TaskStatus.succeeded,
              timeLabel: formatHistoryTime(now),
              metaLabel: parts.join(' · '),
              detail: state.trackMotion
                  ? '跟随画面 · 逐帧追踪水印轨迹'
                  : '静态水印 · 单 Mask 全片',
              createdAt: now.millisecondsSinceEpoch,
              thumbPath: thumbPath,
            ),
          );
    } on Object catch (error) {
      debugPrint('[history] 写入失败：$error');
      // 记录没写成，刚生成的那张缩略图就没有引用者了 —— 删掉，别留孤儿。
      // （图片页的 `_record` 早就有这一步，视频这边漏了 —— 又一次「同类逻辑只改一处」。）
      final orphan = thumbPath;
      if (orphan != null) {
        unawaited(ref.read(thumbnailStoreProvider).remove(orphan));
      }
    }
  }

  Future<void> cancelRepair() async {
    final taskId = state.taskId;
    if (taskId == null) return;
    await ref.read(videoRepairerProvider).cancel(taskId);
  }
}
