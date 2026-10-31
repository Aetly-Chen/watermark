import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/app_card.dart';
import '../../domain/history_item.dart';
import 'history_thumb.dart';

/// 历史列表项。首页「最近处理」和历史页共用同一个组件，避免两处样式漂移。
class HistoryTile extends StatelessWidget {
  const HistoryTile({required this.item, super.key, this.onTap});

  final HistoryItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isVideo = item.kind == HistoryKind.video;
    final ok = item.status == TaskStatus.succeeded;

    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          // 有缩略图就显示成果本身；没有（老记录 / 生成失败）退回图标。
          SizedBox(
            width: 56,
            height: 56,
            child: HistoryThumb(item: item),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      isVideo ? '视频修复' : '图片修复',
                      style: TextStyle(fontSize: 12, color: t.ink3),
                    ),
                    const SizedBox(width: 6),
                    _StatusTag(label: item.status.label, highlight: ok),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        item.timeLabelAt(DateTime.now()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: t.ink3),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  item.metaLabel,
                  style: TextStyle(fontSize: 11.5, color: t.ink3),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: t.ink3, size: 20),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.highlight});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? t.flameSoft : t.line2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: highlight ? t.flameTxt : t.ink3,
        ),
      ),
    );
  }
}
