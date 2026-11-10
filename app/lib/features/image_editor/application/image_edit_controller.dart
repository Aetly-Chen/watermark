import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/format/sizes.dart';
import '../../../core/media/gallery_saver.dart';
import '../../../core/media/thumbnail_store.dart';
import '../../../core/processing/local_basic_image_processor.dart';
import '../../../core/processing/mask_plan.dart';
import '../../../core/processing/processing_error.dart';
import '../../../core/processing/processing_request.dart';
import '../../../core/processing/processing_result.dart';
import '../../history/application/history_providers.dart';
import '../../history/domain/history_format.dart';
import '../../history/domain/history_item.dart';
import '../domain/mask_draft.dart';
import '../infrastructure/mask_composer.dart';

part 'image_edit_controller.g.dart';

/// 图片编辑页的全部状态。
///
/// 刻意不持有 `ui.Image`：那种对象要手动 dispose，塞进不可变 state 里迟早泄漏。
/// 只留原始字节 + 像素尺寸，渲染交给 `Image.memory`，需要像素时临时解码一次。
@immutable
class ImageEditState {
  const ImageEditState({
    this.source,
    this.sourceName,
    this.imageSize,
    this.draft = const MaskDraft.empty(),
    this.tool = MaskTool.rect,
    this.brushSize = 26,
    this.radius = 8,
    this.resultPath,
    this.busy = false,
    this.error,
    this.elapsed,
    this.saving = false,
    this.savedUri,
    this.saveError,
    this.undoDepth = 0,
  });

  final Uint8List? source;

  /// 原始文件名（相册选的原名 / 示例图名）。历史记录要用它当标题。
  final String? sourceName;

  /// 原图像素尺寸（不是显示尺寸）
  final Size? imageSize;

  /// 遮罩草稿：框 + 涂抹笔迹，坐标全部归一化。
  ///
  /// 原来这里只有一个 `Rect?`，而原型上是「画笔涂抹 / 橡皮擦 / 矩形 / 清除」四个工具 ——
  /// 水印形状本来就不都是方的，只给矩形等于把「涂」这个核心交互删了。
  final MaskDraft draft;

  /// 当前工具。默认**矩形** —— 跟原型一致（`data-tool="rect"` 带 `on` 类）。
  /// 先给最粗粒度、最好理解的那个；涂抹是精修手段，不是入口。
  final MaskTool tool;

  /// 画笔直径（逻辑像素，和原型滑块的 8..60 对应）。
  ///
  /// 存显示单位而不是归一化值，是因为这个值的含义是「手指按下去多粗」，
  /// 换算成归一化宽度需要画布的实际渲染宽度 —— 那是画布自己的事（见 `SelectionCanvas`）。
  final double brushSize;

  /// 修复半径（像素）。原型上「修复强度」默认 **标准 · 8 px**。
  ///
  /// ⚠ 历史质量数字（`outside_mae=3.51` 等）都是 6 px 测的，8 px 没有复测过 ——
  /// 集成测试里仍然显式钉 6，免得基准悄悄漂。
  final int radius;

  final String? resultPath;
  final bool busy;
  final String? error;
  final Duration? elapsed;

  /// 正在写相册
  final bool saving;

  /// 已存进相册的 MediaStore URI（`content://media/...`）
  final String? savedUri;
  final String? saveError;

  /// 撤销栈深度。为 0 时「撤销」不可点 —— 界面不需要知道栈里具体存了什么。
  final int undoDepth;

  bool get canUndo => undoDepth > 0;

  bool get hasImage => source != null;
  bool get hasResult => resultPath != null;

  /// 能不能点「开始修复」。判定标准在 `MaskDraft.hasMask`，
  /// 起草稿时 UI 用的是同一个 —— 两处各写一遍迟早分叉。
  bool get canRun => draft.hasMask && !busy && source != null;
  bool get canSave => resultPath != null && !saving && savedUri == null;

  ImageEditState copyWith({
    Uint8List? source,
    String? sourceName,
    Size? imageSize,
    MaskDraft? draft,
    MaskTool? tool,
    double? brushSize,
    int? radius,
    String? resultPath,
    bool? busy,
    String? error,
    Duration? elapsed,
    bool? saving,
    String? savedUri,
    String? saveError,
    bool clearDraft = false,
    int? undoDepth,
    bool clearResult = false,
    bool clearError = false,
    bool clearSave = false,
  }) {
    return ImageEditState(
      source: source ?? this.source,
      sourceName: sourceName ?? this.sourceName,
      imageSize: imageSize ?? this.imageSize,
      draft: clearDraft ? const MaskDraft.empty() : (draft ?? this.draft),
      undoDepth: undoDepth ?? this.undoDepth,
      tool: tool ?? this.tool,
      brushSize: brushSize ?? this.brushSize,
      radius: radius ?? this.radius,
      resultPath: clearResult ? null : (resultPath ?? this.resultPath),
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error),
      elapsed: clearResult ? null : (elapsed ?? this.elapsed),
      saving: saving ?? this.saving,
      savedUri: clearSave ? null : (savedUri ?? this.savedUri),
      saveError: clearSave ? null : (saveError ?? this.saveError),
    );
  }
}

/// 02/03 屏的状态机：导入 → 框选 → 生成 Mask → 调引擎 → 出结果。
@Riverpod(keepAlive: true)
class ImageEditController extends _$ImageEditController {
  static const String sampleAsset = 'assets/samples/cafe.jpg';

  @override
  ImageEditState build() => const ImageEditState();

  /// 系统照片选择器（Android 上是 Photo Picker，不需要读全库权限）
  Future<void> pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      await _adopt(await picked.readAsBytes(), name: picked.name);
    } on PlatformException catch (error) {
      // `image_picker` 的 message 是 `photo_access_denied` / `already_active`
      // 这类英文 code，拼出来是「打开相册失败：photo_access_denied」——
      // 等于把枚举值当文案。原文进日志，界面给能照做的话。
      debugPrint('[image] 选择器失败：${error.code} ${error.message}');
      state = state.copyWith(
        error: '打不开相册。检查一下系统里的相册/照片权限，再点一次。',
      );
    } on Object catch (error) {
      // `readAsBytes` 失败（文件被删、权限）和 `_adopt` 的解码失败都落在这里。
      // 原来只捕 PlatformException → 这两类**静默消失**：用户选完图，界面没反应、
      // 也没提示，只会以为 App 卡了。视频页一直有这层兜底，图片页漏了。
      debugPrint('[image] 打开失败：$error');
      state = state.copyWith(error: '打不开这张图：可能已损坏或格式不支持。换一张试试。');
    }
  }

  /// 调试入口：加载内置示例图，省掉每次都要在相册里翻。
  Future<void> loadSample() async {
    try {
      final data = await rootBundle.load(sampleAsset);
      await _adopt(data.buffer.asUint8List(), name: 'cafe.jpg');
    } on Object catch (error) {
      // 原来这里**没有 try**：asset 缺失或解码失败会变成一条 uncaught async error，
      // 只进 `PlatformDispatcher.onError` 的日志，界面上什么都没发生。
      debugPrint('[image] 示例图加载失败：$error');
      state = state.copyWith(error: '示例图加载失败。改用「从相册选择」试试。');
    }
  }

  Future<void> _adopt(Uint8List bytes, {String? name}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();

    state = ImageEditState(source: bytes, sourceName: name, imageSize: size);
  }

  /// 画布把「用户刚改完的草稿」整份交上来。
  ///
  /// 为什么不做成 `addPoint` / `endStroke` 这类细粒度命令：手势的中间态（一段还没松手的
  /// 笔迹）只存在于画布里，交给控制器保管反而会出现「控制器替画布记半截线」的重复真相。
  /// 画布攒完一次手势就交一份**完整**草稿，控制器只管存。
  void setDraft(MaskDraft draft) {
    if (draft == state.draft) return;
    state = state.copyWith(
      draft: draft,
      clearResult: true,
      clearError: true,
      clearSave: true,
    );
  }

  void setTool(MaskTool tool) {
    if (tool == state.tool) return;
    // 切工具不动草稿：用户涂到一半想改用橡皮，不该把他涂的东西清掉。
    state = state.copyWith(tool: tool, clearError: true);
  }

  void setRadius(double px) {
    final value = px.round().clamp(2, 16);
    if (value == state.radius) return;
    // 改半径会让已有结果失效（同样的选区、不同的修复强度 = 另一张图），
    // 但不清草稿：用户多半只是想「再强一点」，让他重画一遍没道理。
    state = state.copyWith(radius: value, clearResult: true, clearError: true);
  }

  void setBrushSize(double size) {
    // 原型滑块 8..60；夹一下，避免外部传 0 导致笔迹宽度归零（画不出东西还没报错）
    state = state.copyWith(brushSize: size.clamp(4.0, 80.0));
  }

  /// 撤销栈：每项是「一次手势**开始前**」的草稿快照。
  ///
  /// 为什么按手势而不是按 `setDraft` 记：画布在 `onPanUpdate` 里每个点都回调一次，
  /// 一次涂抹会产生几十份草稿。按回调记栈，用户点一次撤销只是退掉一个采样点，
  /// 看着像没反应。所以由画布在 `onPanStart/onPanEnd` 上报手势边界。
  final List<MaskDraft> _undo = <MaskDraft>[];

  /// 本次手势开始时的草稿；手势结束才有意义。
  MaskDraft? _gestureStart;

  /// 栈深上限：草稿本身很轻（矩形 + 点集），30 步足够覆盖一次涂抹 + 几次改框。
  static const int _maxUndo = 30;

  void beginGesture() {
    _gestureStart ??= state.draft;
  }

  void endGesture() {
    final start = _gestureStart;
    _gestureStart = null;
    if (start == null || start == state.draft) return;
    _pushUndo(start);
    state = state.copyWith(undoDepth: _undo.length);
  }

  void _pushUndo(MaskDraft draft) {
    _undo.add(draft);
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  /// 退回到上一个手势之前的草稿。
  ///
  /// 一并清掉结果与错误：草稿变了，旧结果就不再对应当前选区 ——
  /// 留着会让用户以为「改完框还停在旧结果上」。
  void undo() {
    if (_undo.isEmpty) return;
    final previous = _undo.removeLast();
    state = state.copyWith(
      draft: previous,
      undoDepth: _undo.length,
      clearResult: true,
      clearError: true,
      clearSave: true,
    );
  }

  void clearDraft() {
    // 空草稿没什么可清，也别往撤销栈里塞一份「清空 → 又是空」
    if (state.draft.isEmpty) return;
    _pushUndo(state.draft);
    state = state.copyWith(
      clearDraft: true,
      undoDepth: _undo.length,
      clearResult: true,
      clearError: true,
      clearSave: true,
    );
  }

  void reset() {
    state = state.copyWith(
      clearDraft: true,
      clearResult: true,
      clearError: true,
      clearSave: true,
    );
  }

  /// 从结果态退回选区态。保留原草稿 —— 用户多半只是想微调，
  /// 让他重画一遍是没必要的惩罚。
  void backToSelection() {
    state = state.copyWith(
      clearResult: true,
      clearError: true,
      clearSave: true,
    );
  }

  Future<void> run() async {
    final bytes = state.source;
    final draft = state.draft;
    if (bytes == null || draft.isEmpty || state.busy) return;

    state = state.copyWith(
      busy: true,
      clearError: true,
      clearResult: true,
      clearSave: true,
    );

    try {
      final taskId = DateTime.now().millisecondsSinceEpoch.toString();
      final workDir = await getTemporaryDirectory();
      final prepared = await MaskComposer.prepare(
        sourceBytes: bytes,
        draft: draft,
        workDir: workDir,
        taskId: taskId,
      );

      final processor = ref.read(watermarkProcessorProvider);
      final result = await processor.process(
        ProcessingRequest(
          taskId: taskId,
          inputPath: prepared.inputPath,
          outputPath: '${workDir.path}/out_$taskId.png',
          mediaKind: MediaKind.image,
          plan: MaskPlan.fixed(maskPath: prepared.maskPath),
          // 用户在「修复强度」里选的值，一路送到 Kotlin 的 inpaint
          radius: state.radius,
        ),
      );

      state = state.copyWith(
        busy: false,
        resultPath: result.outputPath,
        elapsed: result.elapsed,
      );
      _recordSuccess(result);
    } on ProcessingException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
    } catch (error) {
      // 兜底分支收到的是**任意**异常：`FileSystemException`（临时目录写不进去）、
      // `OutOfMemoryError`、通道序列化失败…… 它们的 `toString()` 是英文 + 内部路径。
      // 拼进用户文案等于把日志糊在界面上，所以只给中文结论，原文进日志。
      debugPrint('[image] 修复失败：$error');
      state = state.copyWith(
        busy: false,
        error: '处理失败。可以换一张图再试；大图先裁掉无关部分会更稳。',
      );
    }
  }

  /// 写一条真实历史。**不 await**：历史写盘失败不该把一次成功的修复变成失败。
  void _recordSuccess(ProcessingResult result) {
    unawaited(_record(result));
  }

  /// 先生成缩略图，再落盘记录。
  ///
  /// 顺序重要：缩略图路径要写进 `history.json`，所以只能在 `add` 之前拿到。
  /// 但整条链都是 fire-and-forget —— 缩略图失败只是没有图，记录照写。
  Future<void> _record(ProcessingResult result) async {
    final now = DateTime.now();
    final id = 'i-${now.microsecondsSinceEpoch}';
    final size = state.imageSize;
    final bytes = state.source?.length ?? 0;
    final meta = <String>[
      if (size != null) '${size.width.round()} × ${size.height.round()}',
      if (bytes > 0) formatBytes(bytes),
    ].join(' · ');

    String? thumbPath;
    try {
      // 用**修好之后**的图当缩略图：历史里该看到成果，不是原图。
      final output = await File(result.outputPath).readAsBytes();
      thumbPath = await ref.read(thumbnailStoreProvider).save(id, output);
    } on Object catch (error) {
      debugPrint('[history] 缩略图生成失败：$error');
    }

    try {
      await ref
          .read(historyItemsProvider.notifier)
          .add(
            HistoryItem(
              id: id,
              title: state.sourceName ?? '图片',
              kind: HistoryKind.image,
              status: TaskStatus.succeeded,
              timeLabel: formatHistoryTime(now),
              metaLabel: meta,
              detail:
                  // 说清楚这次是怎么圈的：涂过就是「涂抹」，只拖了框就是「框选」。
                  // 历史里这两种的成品差别很大（涂抹贴合形状、框选会糊到框内的干净背景），
                  // 用户回头看记录时应该能分辨。
                  '${state.draft.strokes.any((s) => !s.erase) ? '涂抹' : '框选'}修复'
                  ' · 半径 ${state.radius} px'
                  ' · 用时 ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s',
              createdAt: now.millisecondsSinceEpoch,
              thumbPath: thumbPath,
            ),
          );
    } on Object catch (error) {
      debugPrint('[history] 写入失败：$error');
      // 记录没写成，刚才生成的那张缩略图就没有引用者了 —— 删掉，别留孤儿。
      // （正常走不到：`FileHistoryStore.write` 自己吞异常，`add` 的内存更新也不会失败。
      //  但「消失路径都要接」这件事刚刚才在 add() 上栽过一次。）
      final orphan = thumbPath;
      if (orphan != null) {
        unawaited(ref.read(thumbnailStoreProvider).remove(orphan));
      }
    }
  }

  /// 把结果写进系统相册（`Pictures/水印工坊`）。
  ///
  /// 和 [run] 分开：修复失败该重试，保存失败该提示用户去检查存储 —— 混在一起
  /// 会让一次保存失败看起来像「修复没成功」。
  Future<void> saveToGallery() async {
    final path = state.resultPath;
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
          '${stamp.second.toString().padLeft(2, '0')}.png';

      final uri = await ref
          .read(gallerySaverProvider)
          .save(sourcePath: path, displayName: name);
      state = state.copyWith(saving: false, savedUri: uri);
    } on ProcessingException catch (error) {
      state = state.copyWith(saving: false, saveError: error.message);
    } catch (error) {
      // 同上：这里最容易收到 `FileSystemException` / `PlatformException`，
      // 它们的 toString 是英文 + 路径，不能当用户文案。
      debugPrint('[image] 保存失败：$error');
      state = state.copyWith(
        saving: false,
        saveError: '保存失败。检查一下手机存储空间，或稍后再试。',
      );
    }
  }
}
