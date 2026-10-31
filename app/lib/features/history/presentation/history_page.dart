import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
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
        titleSpacing: 20,
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
                color: t.line2,
                borderRadius: BorderRadius.circular(10),
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
                    itemCount: items.length + 1,
                    separatorBuilder: (_, index) =>
                        SizedBox(height: index == items.length - 1 ? 0 : 8),
                    itemBuilder: (context, index) {
                      if (index == items.length) {
                        // 原型里的那条说明：删除记录 ≠ 删除相册文件
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: AppCard(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 16,
                                  color: t.ink3,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '删除记录不会删掉相册里的成品文件，两者互相独立，避免误删已经导出的图片与视频。',
                                    style: textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
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
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? t.paper : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? t.line : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? t.ink : t.ink3,
            ),
          ),
        ),
      ),
    );
  }
}
