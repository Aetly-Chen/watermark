import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/before_after_view.dart';
import '../../../core/widgets/editor_canvas_layout.dart';
import '../application/image_edit_controller.dart';
import '../domain/mask_draft.dart';
import 'widgets/selection_canvas.dart';

/// 02 图片去水印 / 03 图片修复结果（同一路由，按是否有结果切换展示）。
class ImageEditorPage extends ConsumerWidget {
  const ImageEditorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(imageEditControllerProvider);
    final controller = ref.read(imageEditControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('图片去水印'),
        actions: [
          if (state.hasImage)
            TextButton(
              onPressed: state.busy ? null : controller.reset,
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.hasImage) ...[
                  Row(
                    children: [
                      _Meta(
                        label: '原图',
                        value: state.imageSize == null
                            ? '—'
                            : '${state.imageSize!.width.toInt()} × ${state.imageSize!.height.toInt()}',
                      ),
                      const SizedBox(width: 18),
                      _Meta(label: '遮罩', value: maskLabel(state)),
                      const Spacer(),
                      if (state.elapsed != null)
                        Text(
                          '耗时 ${state.elapsed!.inMilliseconds} ms',
                          style: TextStyle(fontSize: 11.5, color: t.ink3),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 三个工具都是**真的能切**。之前只有一个「矩形选区」，
                  // 而且它是个假按钮（onTap 给的空函数）—— 原型上明明是四个工具。
                  Row(
                    children: [
                      _ToolChip(
                        icon: Icons.crop_free_rounded,
                        label: '矩形',
                        selected: state.tool == MaskTool.rect,
                        onTap: state.busy
                            ? null
                            : () => controller.setTool(MaskTool.rect),
                      ),
                      const SizedBox(width: 8),
                      _ToolChip(
                        icon: Icons.brush_outlined,
                        label: '涂抹',
                        selected: state.tool == MaskTool.brush,
                        onTap: state.busy
                            ? null
                            : () => controller.setTool(MaskTool.brush),
                      ),
                      const SizedBox(width: 8),
                      _ToolChip(
                        icon: Icons.auto_fix_normal_outlined,
                        label: '橡皮',
                        selected: state.tool == MaskTool.eraser,
                        onTap: state.busy
                            ? null
                            : () => controller.setTool(MaskTool.eraser),
                      ),
                      const SizedBox(width: 8),
                      _ToolChip(
                        icon: Icons.backspace_outlined,
                        label: '清除',
                        selected: false,
                        onTap: state.busy || state.draft.isEmpty
                            ? null
                            : controller.clearDraft,
                      ),
                    ],
                  ),
                  // 画笔大小只在涂抹/橡皮下出现：矩形不需要它，
                  // 一直摆在那儿会让人以为「框的大小」也能调。
                  if (state.tool != MaskTool.rect) ...[
                    const SizedBox(height: 4),
                    _SliderRow(
                      label: '笔宽',
                      valueLabel: '${state.brushSize.round()}',
                      value: state.brushSize,
                      min: 8,
                      max: 60,
                      divisions: 26,
                      onChanged: state.busy ? null : controller.setBrushSize,
                    ),
                  ],
                  // 修复强度：这个参数在引擎里一直都有（Telea 的邻域半径），
                  // 但界面上从来没有入口 —— 原型上却有，而且用户确实需要它：
                  // 水印压在细纹理上时要小一点，压在纯色背景上大一点更干净。
                  const SizedBox(height: 2),
                  _SliderRow(
                    label: '修复强度',
                    valueLabel: '${state.radius} px',
                    value: state.radius.toDouble(),
                    min: 2,
                    max: 16,
                    divisions: 14,
                    onChanged: state.busy
                        ? null
                        : (v) => controller.setRadius(v),
                  ),
                  if (state.error != null) ...[
                    const SizedBox(height: 10),
                    _ErrorBanner(message: state.error!),
                  ],
                  const SizedBox(height: 12),
                ],
              ],
            ),
        ),

        // 主操作固定在底部：横屏 / 分屏下控制面板会变成可滚动，
        // 按钮跟着滚走的话，转屏后第一眼找不到操作入口。
        pinned: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
                if (state.hasResult) ...[
                  if (state.saveError != null) ...[
                    _ErrorBanner(message: state.saveError!),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: '重新定位选区',
                          variant: AppButtonVariant.secondary,
                          onPressed: state.saving
                              ? null
                              : controller.backToSelection,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppButton(
                          label: state.savedUri != null
                              ? '已存入相册'
                              : state.saving
                              ? '保存中…'
                              : '保存到相册',
                          icon: state.savedUri == null
                              ? Icons.download_rounded
                              : Icons.check_rounded,
                          onPressed: state.canSave
                              ? controller.saveToGallery
                              : null,
                        ),
                      ),
                    ],
                  ),
                  if (state.savedUri != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '已保存到「相册 / Pictures / 水印工坊」',
                      textAlign: TextAlign.center,
                      style: textTheme.bodySmall,
                    ),
                  ],
                ] else if (state.hasImage)
                  AppButton(
                    label: state.busy ? '修复中…' : '开始修复',
                    icon: state.busy ? null : Icons.auto_fix_high_rounded,
                    onPressed: state.canRun ? controller.run : null,
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: '从相册选择',
                          variant: AppButtonVariant.secondary,
                          icon: Icons.photo_library_outlined,
                          onPressed: controller.pickFromGallery,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: AppButton(
                          label: '用示例图',
                          onPressed: controller.loadSample,
                        ),
                      ),
                    ],
                  ),
                if (!state.hasImage) ...[
                  const SizedBox(height: 8),
                  Text(
                    '示例图是内置的咖啡馆照片，用来快速试链路，不经过相册。',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall,
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CanvasArea extends StatelessWidget {
  const _CanvasArea({required this.state, required this.controller});

  final ImageEditState state;
  final ImageEditController controller;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    if (!state.hasImage) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: 40,
              color: t.cream.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 10),
            Text(
              '还没有选图',
              style: TextStyle(
                fontSize: 13,
                color: t.cream.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      );
    }

    if (state.resultPath != null) {
      // 两张图同尺寸（修复不改分辨率，是必做校验的副产品），同一个 BoxFit 下
      // 位置完全重合，对比时不会错位。
      return BeforeAfterSwitch(
        // 同视频页：State 里记着上次停在哪一态，换结果就要换 key，
        // 否则「修复后」会从上一条记录带过来。
        key: ValueKey('compare-${state.resultPath}'),
        before: Image.memory(
          state.source!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        after: Image.file(
          File(state.resultPath!),
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        imageAspect: state.imageSize == null || state.imageSize!.height == 0
            ? null
            : state.imageSize!.width / state.imageSize!.height,
      );
    }

    return SelectionCanvas(
      bytes: state.source!,
      imageSize: state.imageSize!,
      draft: state.draft,
      tool: state.tool,
      brushSize: state.brushSize,
      onDraftChanged: controller.setDraft,
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
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: t.ink3)),
        const SizedBox(width: 5),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
        ),
      ],
    );
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? t.flameSoft : t.paper,
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          border: Border.all(color: selected ? t.flame : t.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? t.flameTxt : t.ink2),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? t.flameTxt : t.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
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

/// 「遮罩」那一格的文案。
///
/// 抽成顶层函数而不是塞在 build 里：这里的换算（归一化 → 原图像素）是**容易错**的一段，
/// 错了会显示成「框了 300 × 448」但实际修的是别处。函数式写法能直接单测，
/// 不必为了断言一句话去渲染整个页面。
String maskLabel(ImageEditState state) {
  final draft = state.draft;
  if (draft.isEmpty) return '未标注';

  final size = state.imageSize;
  final rect = draft.rect;
  final brushCount = draft.strokes.where((s) => !s.erase).length;

  final parts = <String>[];
  if (rect != null && rect.width > 0 && rect.height > 0) {
    if (size == null) {
      parts.add('框选');
    } else {
      parts.add(
        '${(rect.width * size.width).round()} × '
        '${(rect.height * size.height).round()}',
      );
    }
  }
  if (brushCount > 0) parts.add('涂抹 $brushCount 笔');
  if (parts.isEmpty) return '未标注';
  return parts.join(' · ');
}

/// 一行「标签 + 滑块 + 当前值」。
///
/// 抽出来是因为笔宽和修复强度是同一个形状 —— 两份手写 Row 迟早走样
/// （一个宽度 24、一个 30，一个不带 label）。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(label, style: TextStyle(fontSize: 12, color: t.ink3)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            valueLabel,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: t.ink3),
          ),
        ),
      ],
    );
  }
}
