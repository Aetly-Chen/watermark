import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../core/theme/app_tokens.dart';
import '../application/history_providers.dart';
import '../domain/history_item.dart';
import 'widgets/history_tile.dart';

/// 07 历史记录。
///
/// 筛选状态放在 provider 里（`historyFilterProvider`），
/// 列表由 `visibleHistoryProvider` 派生 —— 页面本身无状态，重建只重算列表。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final all = ref.watch(historyItemsProvider);
    final filter = ref.watch(historyFilterProvider);
    final items = ref.watch(visibleHistoryProvider);

    final imageCount = all.where((i) => i.kind == HistoryKind.image).length;
    final videoCount = all.where((i) => i.kind == HistoryKind.video).length;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppTokens.gutter,
        toolbarHeight: 64,
        title: Text('历史记录', style: textTheme.titleLarge),
        actions: [
          IconButton(
            tooltip: '清空记录',
            onPressed: () => _confirmClear(context, ref, all.length),
            icon: Icon(Icons.delete_sweep_outlined, color: t.ink2),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // ── 分段筛选 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: t.track,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.line),
              ),
              child: Row(
                children: [
                  _FilterTab(
                    label: '全部 ${all.length}',
                    selected: filter == null,
                    onTap: () =>
                        ref.read(historyFilterProvider.notifier).setKind(null),
                  ),
                  _FilterTab(
                    label: '图片 $imageCount',
                    selected: filter == HistoryKind.image,
                    onTap: () => ref
                        .read(historyFilterProvider.notifier)
                        .setKind(HistoryKind.image),
                  ),
                  _FilterTab(
                    label: '视频 $videoCount',
                    selected: filter == HistoryKind.video,
                    onTap: () => ref
                        .read(historyFilterProvider.notifier)
                        .setKind(HistoryKind.video),
                  ),
                ],
              ),
            ),
          ),

          // ── 列表 ──
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 34,
                          color: t.ink3.withValues(alpha: 0.45),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          filter == null ? '还没有处理记录' : '这个分类下没有记录',
                          style: TextStyle(fontSize: 14, color: t.ink2),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '修完的图片和视频会出现在这里',
                          style: TextStyle(fontSize: 12, color: t.ink3),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return HistoryTile(
                        item: item,
                        onTap: () => context.pushNamed(
                          AppRoutes.historyDetailName,
                          pathParameters: {'id': item.id},
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 清空全部记录。
  ///
  /// 原来是 `_showManageHint` —— 一个只会弹「批量管理待接入本地数据库后开放」的假按钮，
  /// 而数据库早就接上了。现在做成真事：**二次确认**之后清空，并且明确告诉用户
  /// 相册里的成品不受影响（这也是列表底部那条说明的含义）。
  Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (count == 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('还没有记录可清空')),
      );
      return;
    }

    final t = AppTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: t.paper,
        title: Text(
          '清空 $count 条记录？',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
        ),
        content: Text(
          '这里只删处理记录，相册里的成品文件不会被动。此操作不可撤销。',
          style: TextStyle(fontSize: 13, height: 1.6, color: t.ink2),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('取消', style: TextStyle(color: t.ink3)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('清空', style: TextStyle(color: t.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(historyItemsProvider.notifier).clear();
    messenger.showSnackBar(
      SnackBar(content: Text('已清空 $count 条记录，相册里的成品未受影响')),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final radius = BorderRadius.circular(9);

    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        height: 34,
        decoration: BoxDecoration(
          color: selected ? t.surfaceElevated : Colors.transparent,
          borderRadius: radius,
          border: Border.all(
            color: selected ? t.line : Colors.transparent,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ]
              : const [],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            hoverColor: t.hoverTint,
            splashColor: t.flame.withValues(alpha: 0.12),
            highlightColor: t.hoverTint,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? t.ink : t.ink2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
