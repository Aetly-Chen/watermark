import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/media/video_probe.dart';
import '../../../core/media/video_repairer.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/before_after_view.dart';
import '../../../core/widgets/editor_canvas_layout.dart';
import '../../../core/widgets/video_preview_dialog.dart';
import '../../image_editor/domain/mask_draft.dart';
import '../../image_editor/presentation/widgets/selection_canvas.dart';
import '../application/video_edit_controller.dart';

/// 04 视频去水印：选视频 → 读元数据 → 在封面帧上框选 → 逐帧修复。
///
/// 默认「镜头静止」：封面帧上框的位置原样套到每一帧。开了「跟随画面」就用关键帧
/// 光流（相似变换 4dof）把选框跟着内容一起搬 —— 前提是场景刚性，画面本身在变形
/// （花瓣绽放那类）时任何全局变换都对不齐，这是能力边界不是精度问题。
///
/// 不给用户选「静态/动态水印」这种术语，只问「水印到底动没动」。见 [_MotionToggle]。
class VideoEditorPage extends ConsumerWidget {
  const VideoEditorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(videoEditControllerProvider);
    final controller = ref.read(videoEditControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('视频去水印'),
        actions: [
          if (state.hasVideo)
            TextButton(
              onPressed: state.busy || state.processing ? null : controller.reset,
              style: TextButton.styleFrom(foregroundColor: t.flameTxt),
              child: const Text('重置选区'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: EditorCanvasLayout(
        // ── 画布 ──
        canvas: Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.media,
            borderRadius: BorderRadius.circular(AppTokens.radiusCard),
          ),
          child: _CanvasArea(state: state, controller: controller),
        ),

        // ── 下方面板 ──
        controls: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, state.hasVideo ? 10 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.meta != null) ...[
                  Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    children: [
                      _Meta(label: '时长', value: state.meta!.durationLabel),
                      _Meta(label: '分辨率', value: state.meta!.resolutionLabel),
                      _Meta(label: '体积', value: state.meta!.sizeLabel),
                      _Meta(
                        label: '音轨',
                        value: state.meta!.hasAudio ? '有' : '无',
                      ),
                      if (state.meta!.isRotated)
                        _Meta(label: '旋转', value: '${state.meta!.rotation}°'),
                      _Meta(
                        label: '封面',
                        value: state.posterSize == null
                            ? '—'
                            : '${state.posterSize!.width.toInt()} × ${state.posterSize!.height.toInt()}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                if (state.error != null) ...[
                  _ErrorBanner(message: state.error!),
                  const SizedBox(height: 10),
                ],
                if (state.processing) ...[
                  _Progress(state: state),
                  const SizedBox(height: 10),
                ],
                if (state.result != null && !state.processing) ...[
                  _ResultCard(result: state.result!),
                  const SizedBox(height: 8),
                  // 两件事并列：先看整段效果，再决定存不存。
                  // 「预览」只放一帧对比是看不出来的 —— 跟随模式下会不会抖、
                  // 有没有跳帧，必须播一遍。
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: '预览效果',
                          icon: Icons.play_circle_outline_rounded,
                          variant: AppButtonVariant.secondary,
                          onPressed: () => VideoPreviewDialog.show(
                            context,
                            state.result!.outputPath,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        // 结果只在临时目录里，没有这一步等于「修了拿不出来」
                        child: AppButton(
                          label: state.savedUri != null
                              ? '已保存到相册'
                              : (state.saving ? '正在保存…' : '保存到相册'),
                          icon: state.savedUri != null
                              ? Icons.check_rounded
                              : Icons.download_rounded,
                          variant: AppButtonVariant.secondary,
                          onPressed: state.canSave
                              ? controller.saveToGallery
                              : null,
                        ),
                      ),
                    ],
                  ),
                  if (state.result!.maskRatioTooBig) ...[
                    const SizedBox(height: 6),
                    // 大洞不是参数能修的：TELEA 在 24.9% 画面的矩形洞上只会填出一块 X 形灰斑
                    // （实测）。与其让用户以为「修坏了」，不如当场说清原因和出路。
                    _Hint(
                      text: '选区占画面 '
                          '${(state.result!.maskRatio * 100).round()}%，'
                          '这块只能填成一片平滑色块；想更自然，请只框住水印本身再修一次',
                    ),
                  ],
                  if (state.saveError != null) ...[
                    const SizedBox(height: 6),
                    _Hint(text: state.saveError!),
                  ],
                  const SizedBox(height: 10),
                ],
                if (state.selection != null && state.meta != null) ...[
                  _Hint(text: selectionLabel(state.selection!, state.meta!)),
                  const SizedBox(height: 8),
                ],
                if (state.hasVideo && !state.processing) ...[
                  _MotionToggle(
                    trackMotion: state.trackMotion,
                    onChanged: controller.setTrackMotion,
                  ),
                  const SizedBox(height: 10),
                ],
                // 主按钮不放在这里，交给 EditorCanvasLayout 的 pinned 槽：
                // 横屏/分屏下控制面板会变成可滚动，主操作不该被滚出屏幕。
                if (!state.hasVideo) ...[
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: '从相册选择',
                          variant: AppButtonVariant.secondary,
                          icon: Icons.video_library_outlined,
                          onPressed: state.busy ? null : controller.pickFromGallery,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppButton(
                          label: state.busy ? '读取中…' : '用示例视频',
                          onPressed: state.busy ? null : controller.loadSample,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '示例视频是内置的 1 MB 短片（MDN CC0），用来跑通探测与帧提取，不经过相册。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall,
                  ),
                ],
              ],
            ),
        ),

        // 主操作固定在底部，不随控制面板滚动（横屏/分屏下尤其重要）
        pinned: state.hasVideo
            ? Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: AppButton(
                  label: state.processing
                      ? '取消修复'
                      : (state.result != null ? '重新修复' : '开始修复'),
                  icon: state.processing
                      ? Icons.stop_rounded
                      : Icons.auto_fix_high_rounded,
                  variant: state.processing
                      ? AppButtonVariant.secondary
                      : AppButtonVariant.primary,
                  onPressed: !state.canRepair && !state.processing
                      ? null
                      : (state.processing
                            ? controller.cancelRepair
                            : controller.startRepair),
                ),
              )
            : null,
      ),
    );
  }
}

/// 「水印静止 / 跟随画面」开关。
///
/// 这是原型的取舍：不让用户选「静态水印 / 动态水印」这种术语，
/// 只给一个「它到底动没动」的选择，并且**默认不动**（多数场景水印是钉死的）。
///
/// 文案说的是**适用前提**，不是免责声明。相似变换的前提是场景刚性 + 相机在动：
/// 实测在画面内容本身变形的素材上（花瓣绽放那类），4/6/8 自由度全都对不齐，
/// 跟随必然偏 —— 这不是精度问题，用户开了也没用，得让他知道该关。
class _MotionToggle extends StatelessWidget {
  const _MotionToggle({required this.trackMotion, required this.onChanged});

  final bool trackMotion;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Icon(Icons.moving_rounded, size: 20, color: t.flameTxt),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trackMotion ? '跟随画面' : '水印静止',
                  style: textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  trackMotion
                      ? '镜头动，选框跟着走。画面本身在变形时会跟不准'
                      : '选框固定不动。水印会动的话会被漏掉',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Switch(value: trackMotion, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _CanvasArea extends StatelessWidget {
  const _CanvasArea({required this.state, required this.controller});

  final VideoEditState state;
  final VideoEditController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    if (!state.hasVideo) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_outlined,
              size: 40,
              color: t.cream.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              state.busy ? '正在读取视频…' : '还没有选视频',
              style: TextStyle(fontSize: 13, color: t.cream.withValues(alpha: 0.55)),
            ),
          ],
        ),
      );
    }

    // 出结果之后画布换成「修复前 / 对比 / 修复后」。
    //
    // 之前修完仍然显示带水印的封面帧 + 选框，用户刚修完就看到水印还在，
    // 很容易当成「没修干净」。首帧和封面帧是同一时间点，直接并排就是可信的对比。
    if (state.result != null && state.resultFrame != null) {
      return BeforeAfterSwitch(
        // 每次新结果都换 key：三段切换是 StatefulWidget，State 里记着用户上次
        // 停在哪一态。不换 key 的话，上一件作品的「修复后」会被带到下一件上 ——
        // 新结果默认必须是「对比」，否则并排看不出差别这件事就白做了。
        key: ValueKey('compare-${state.result!.outputPath}'),
        before: Image.memory(
          state.poster!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        after: Image.memory(
          state.resultFrame!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        imageAspect: state.posterSize == null || state.posterSize!.height == 0
            ? null
            : state.posterSize!.width / state.posterSize!.height,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 转码中锁住画布：Mask 在任务开始时就已经发给 native 了，
        // 这时候再拖选区只会让用户以为改得动。
        AbsorbPointer(
          absorbing: state.processing,
          child: SelectionCanvas(
            bytes: state.poster!,
            imageSize: state.posterSize!,
            // 视频只用矩形：Mask 要逐帧跟着运动轨迹走，而「涂抹的笔迹」还没有
            // 下发给原生（原型里那句「视频逐帧涂抹」目前没有实现）。
            // 这里也不给涂抹入口 —— 给了就是又一个「看着能点、其实不生效」。
            draft: MaskDraft(rect: state.selection),
            tool: MaskTool.rect,
            brushSize: 26,
            onDraftChanged: (draft) => controller.setSelection(draft.rect),
          ),
        ),
        Positioned(
          top: 10,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: t.media.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '封面帧 · 框选水印位置',
                style: TextStyle(
                  fontSize: 11,
                  color: t.cream.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: t.ink3)),
        const SizedBox(width: 5),
        Text(
          value,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.ink),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: t.ink2, fontFeatures: const []),
      ),
    );
  }
}

/// 转码进度。
///
/// 开了「跟随画面」时原生侧跑两趟（先算全片轨迹、再逐帧修），所以这里是**两条**
/// 各自独立的进度条，各自从 0 走到 100 —— 不合成一个百分比。
/// 合成就要编权重（比如「分析占 30%」），而实测分析只占总耗时 4%，
/// 那会让进度条飞快冲到 30% 再卡住，纯粹是骗人。
///
/// 关掉跟随只有一趟，就只显示「逐帧修复」，版面与之前一致。
class _Progress extends StatelessWidget {
  const _Progress({required this.state});

  final VideoEditState state;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final motion = state.motionFraction;
    final repair = state.progressFraction;
    // 第一趟报完真帧数之后，修复那一趟的分母就不是估计值了，可以不写「约」
    final approximate = !state.motionFinished;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (motion != null) ...[
            _PassBar(
              title: '分析镜头运动',
              // 第一趟跑完时它自己报的就是真帧数（分母=分子），这时不该再写「约」
              note: state.motionFinished
                  ? '全片 ${state.motionDone} 帧'
                  : '${state.motionDone} / 约 ${state.motionTotal} 帧',
              fraction: motion,
              trailing: state.motionFinished
                  ? '完成'
                  : '${(motion * 100).round()}%',
              done: state.motionFinished,
            ),
            const SizedBox(height: 10),
          ],
          _PassBar(
            title: '逐帧修复',
            note: repair == null
                ? (motion == null ? '等待第一帧' : '等待第一趟跑完')
                : '${state.progressDone} / '
                      '${approximate ? '约 ' : ''}${state.progressTotal} 帧',
            fraction: repair,
            trailing: repair == null ? '等待' : '${(repair * 100).round()}%',
            done: false,
          ),
          const SizedBox(height: 6),
          Text(
            state.trackMotion
                ? '跟随已开启：水印会按画面运动移动。'
                : '镜头静止假设：封面帧上框的位置会套到每一帧。',
            style: TextStyle(fontSize: 11, color: t.ink3),
          ),
        ],
      ),
    );
  }
}

/// 一条阶段的进度：标题 + 百分比 + 进度条。
class _PassBar extends StatelessWidget {
  const _PassBar({
    required this.title,
    required this.note,
    required this.fraction,
    required this.trailing,
    required this.done,
  });

  final String title;
  final String note;
  final double? fraction;
  final String trailing;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    // null 表示「这趟还没开始」。**不能把 null 直接交给 LinearProgressIndicator**：
    // 它会把 null 当成「不确定态」，渲染一条来回滚动的动画条 ——
    // 真机上抓到过：截图里「等待」那条是一根几乎满格的橙条，看着像已经跑完了。
    // 空着就是空着。
    final barValue = done ? 1.0 : (fraction ?? 0.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: fraction == null && !done ? t.ink3 : t.ink,
                ),
              ),
            ),
            Text(
              trailing,
              style: TextStyle(
                fontSize: 12,
                color: done ? t.flameTxt : t.ink3,
                fontWeight: done ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: barValue,
            minHeight: 5,
            backgroundColor: t.line,
            valueColor: AlwaysStoppedAnimation(done ? t.flameTxt : t.flame),
          ),
        ),
        const SizedBox(height: 3),
        Text(note, style: TextStyle(fontSize: 10.5, color: t.ink3)),
      ],
    );
  }
}

/// 修复完成的摘要。故意把「跳过帧数」也露出来 —— 它不为 0 的时候说明解码通路有问题，
/// 藏起来就成了假成功。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final VideoRepairResult result;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 16, color: t.flame),
              const SizedBox(width: 6),
              Text(
                '修复完成',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${result.width} × ${result.height} · ${result.frames} 帧 · '
            '${result.sizeLabel} · 音轨${result.hasAudio ? '保留' : '无'}',
            style: TextStyle(fontSize: 11.5, color: t.ink2),
          ),
          const SizedBox(height: 3),
          Text(
            '耗时 ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s '
            '(${result.framesPerSecond.toStringAsFixed(1)} fps)'
            '${result.skippedFrames > 0 ? ' · 跳过 ${result.skippedFrames} 帧' : ''}',
            style: TextStyle(fontSize: 11, color: t.ink3),
          ),
          // 开了「跟随画面」却看不到任何数字，用户没法判断它到底跟没跟上。
          // 原生一直在算，Dart 也解析进结果里了，只是从来没显示过。
          if (result.motionTracked + result.motionFailed > 0) ...[
            const SizedBox(height: 3),
            Text(
              motionSummary(result),
              style: TextStyle(fontSize: 11, color: t.ink3),
            ),
          ],
        ],
      ),
    );
  }
}

/// 修复摘要里「跟随」那一行。
///
/// 只在**真的跟踪过**（`motionTracked + motionFailed > 0`）时显示：镜头静止的视频
/// 不显示这一行，免得满屏 0 让人以为哪里坏了。
///
/// 两个措辞上的坑：
///   · `motionShiftPx` 是**首帧到末帧**的位移模长（原生 `cumulativeShiftPx`），
///     不是各帧位移之和 —— 所以写「首末位移」，不写「累计位移」，后者会被读成
///     「一共挪了多少」。
///   · `keyframeSwitches` 是**换了几次**关键帧，不是「有几个关键帧」。差一，
///     而且首帧算不算取决于实现，写「换关键帧 N 次」不需要猜。
String motionSummary(VideoRepairResult result) {
  final total = result.motionTracked + result.motionFailed;
  final parts = <String>[
    total > result.motionTracked
        ? '跟随 ${result.motionTracked} / $total 帧对齐'
        : '跟随 $total 帧全部对齐',
    '首末位移 ${result.motionShiftPx.round()} px',
  ];
  if (result.keyframeSwitches > 0) parts.add('换关键帧 ${result.keyframeSwitches} 次');
  return parts.join(' · ');
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: t.flameSoft,
      borderColor: t.flameSoft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: t.flameTxt),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「已框选」那一行的文案。
///
/// 原来直接露归一化坐标：`已框选：归一化 0.250, 0.100 → 0.506, 0.300`。
/// 「归一化」是我们的术语，不是用户的 —— 这串数字对他没有任何意义，
/// 他关心的是「我框住多大一块东西」。所以和图片页统一按**像素**说（图片页的
/// `maskLabel` 显示「300 × 448」）。
///
/// 用 `display*` 而不是 `width/height`：框是用户在**显示坐标系**里画出来的，
/// 竖拍视频 `rot=90` 时两者正好相反，用错会把宽高说反。尺寸缺失时只说
/// 「已框选」，不编一个数字出来。
String selectionLabel(Rect rect, VideoMeta meta) {
  const fallback = '已框选';
  if (meta.displayWidth <= 0 || meta.displayHeight <= 0) return fallback;
  final w = (rect.width * meta.displayWidth).round();
  final h = (rect.height * meta.displayHeight).round();
  if (w <= 0 || h <= 0) return fallback;
  return '已框选 $w × $h';
}
