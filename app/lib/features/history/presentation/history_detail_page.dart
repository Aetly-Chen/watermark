import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../application/history_providers.dart';
import '../domain/history_item.dart';
import 'widgets/history_thumb.dart';

/// 历史详情。带路由参数（`/history/:id`）的示例页：
/// 参数从 `state.pathParameters` 取出后直接喂给 family provider。
class HistoryDetailPage extends ConsumerWidget {
  const HistoryDetailPage({required this.taskId, super.key});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final item = ref.watch(historyItemByIdProvider(taskId));

    return Scaffold(
      appBar: AppBar(title: const Text('处理详情')),
      body: item == null
          ? Center(
              child: Text(
                '这条记录不存在（id: $taskId）',
                style: TextStyle(color: t.ink3),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                // 原来这里是个固定 200px 的深色框，里面只有一个图标 ——
                // 永远加载不出来的预览区，比没有预览更让人以为坏了。
                // 现在有缩略图就显示成果，没有才退回图标。
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: HistoryThumb(
                    item: item,
                    radius: AppTokens.radiusCard,
                    iconSize: 40,
                    cacheWidth: 720,
                  ),
                ),
                const SizedBox(height: 12),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: textTheme.titleMedium),
                      const SizedBox(height: 8),
                      // 类型原来是 `item.kind.name`，中文界面里冒出英文 image/video
                      _Row(label: '类型', value: item.kind.label),
                      _Row(label: '状态', value: item.status.label),
                      _Row(label: '完成时间', value: item.timeLabelAt(DateTime.now())),
                      _Row(label: '媒体信息', value: item.metaLabel),
                      if (item.detail != null)
                        _Row(label: '处理参数', value: item.detail!),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 说清楚这个页面的边界：历史只存元信息，不存素材。
                // 不说这一句，用户点「再处理」会以为能拿回原来那张图。
                Text(
                  '历史只保留处理记录。成品已导出到手机相册，原素材不留副本 —— '
                  '要再修一次需要重新选文件。',
                  style: textTheme.bodySmall?.copyWith(height: 1.6),
                ),
                const SizedBox(height: 20),
                AppButton(
                  label: item.kind == HistoryKind.video
                      ? '再处理一个视频'
                      : '再处理一张图片',
                  icon: Icons.refresh_rounded,
                  onPressed: () => context.pushNamed(
                    item.kind == HistoryKind.video
                        ? AppRoutes.videoEditorName
                        : AppRoutes.imageEditorName,
                  ),
                ),
              ],
            ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: TextStyle(fontSize: 13, color: t.ink3)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: t.ink),
            ),
          ),
        ],
      ),
    );
  }
}
