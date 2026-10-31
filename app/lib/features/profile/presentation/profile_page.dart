import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_info.dart';
import '../../../core/format/sizes.dart';
import '../../../core/storage/app_cache.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/theme/theme_mode_controller.dart';
import '../../../core/widgets/app_card.dart';
import '../../history/application/history_providers.dart';
import '../../history/domain/history_item.dart';

/// 08 我的 / 设置。
///
/// 主题切换是「Riverpod 状态 → MaterialApp.themeMode」这条链路的现场演示：
/// 点一下 segmented，整棵树换令牌，不需要任何 setState 或 InheritedWidget 手写。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    final mode = ref.watch(themeModeControllerProvider);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        toolbarHeight: 64,
        title: Text('我的', style: textTheme.titleLarge),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          // ── 工作台概览 ──
          AppCard(
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: t.flameSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.offline_bolt_outlined,
                    color: t.flameTxt,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('本地工作台', style: textTheme.titleMedium),
                      const SizedBox(height: 3),
                      Text(_summary(ref), style: textTheme.bodySmall),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: t.flameSoft,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '已启用',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: t.flameTxt,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.gapL),

          // ── 主题模式 ──
          Text('主题模式', style: textTheme.bodyMedium),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: t.line2,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                for (final entry in <(ThemeMode, String)>[
                  (ThemeMode.system, '跟随系统'),
                  (ThemeMode.light, '浅色'),
                  (ThemeMode.dark, '深色'),
                ])
                  Expanded(
                    child: _ModeTab(
                      label: entry.$2,
                      selected: mode == entry.$1,
                      onTap: () => ref
                          .read(themeModeControllerProvider.notifier)
                          .setMode(entry.$1),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.gapL),

          // ── 设置项 ──
          //
          // 这里只放**真的会做事**的项。原来还有一行「默认修复质量 · 高清」，
          // 点了只弹「暂未开放」—— 那是装饰不是设置，删了比留着诚实。
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingRow(
                  icon: Icons.cleaning_services_outlined,
                  title: '清理缓存',
                  trailing: _cacheLabel(ref.watch(cacheSnapshotProvider)),
                  onTap: () => _clearCache(context, ref),
                ),
                Divider(height: 1, color: t.line2, indent: 52),
                _SettingRow(
                  icon: Icons.info_outline_rounded,
                  title: '关于水印工坊',
                  // 版本来自 `package_info_plus`（源头是 pubspec 的 version:），
                  // 不再写死 —— 三处硬编码改版本时必漏。
                  trailing: ref.watch(appInfoProvider).label,
                  onTap: () => _showAbout(context, ref.read(appInfoProvider)),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppTokens.gapL),
          Text(
            '所有处理均在本机完成，素材不会上传。\n'
            '水印工坊 ${ref.watch(appInfoProvider).label} · 本地优先',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(height: 1.7),
          ),
        ],
      ),
    );
  }

  /// 概览数字来自真实历史 —— 原本文案是写死的「已完成 15 项 · 26.8 MB」，
  /// 那是假数据，和「历史页固定 6 条」是同一个毛病。
  String _summary(WidgetRef ref) {
    final items = ref.watch(historyItemsProvider);
    if (items.isEmpty) return '还没有处理记录';
    final done = items.where((i) => i.status == TaskStatus.succeeded).length;
    return '已完成 $done 项 · 共 ${items.length} 条记录';
  }

  /// 缓存体积文案。读盘期间是省略号、失败是破折号 —— 不拿 0 冒充「没有缓存」。
  String _cacheLabel(AsyncValue<CacheSnapshot> cache) {
    // Riverpod 3 里 `value` 就是可空的（原来叫 valueOrNull），不再抛异常。
    final data = cache.value;
    if (data == null) return cache.hasError ? '—' : '…';
    if (data.isEmpty) return '无';
    return formatBytes(data.removableBytes);
  }

  /// 真的清。
  ///
  /// 成果类文件（`out_*.png` / `fixed_*.mp4`）由 store 保护，这里只负责把结果说清楚：
  /// 释放了多少、保住了什么、几个文件被占用。少说一句，用户就会以为「点了没反应」。
  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final report = await ref.read(appCacheStoreProvider).clear();
    ref.invalidate(cacheSnapshotProvider);

    final parts = <String>[
      report.freedBytes > 0
          ? '已释放 ${formatBytes(report.freedBytes)}'
          : '没有可清理的缓存',
      if (report.hasKept)
        '保留 ${report.keptCount} 个未导出的成果'
            '（${formatBytes(report.keptBytes)}）',
      if (report.failedCount > 0) '${report.failedCount} 个文件被占用',
    ];
    messenger.showSnackBar(SnackBar(content: Text(parts.join(' · '))));
  }

  void _showAbout(BuildContext context, AppInfo appInfo) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final t = AppTokens.of(dialogContext);
        return AlertDialog(
          backgroundColor: t.paper,
          title: Text(
            '水印工坊 ${appInfo.label}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
          content: Text(
            '所有处理都在本机完成，素材不上传。\n\n'
            '图片走 TELEA 修复；视频逐帧修复，音轨原样透传。'
            '${appInfo.buildNumber.isEmpty ? '' : '\n\n构建号 ${appInfo.buildLabel}'}',
            style: TextStyle(fontSize: 13, height: 1.6, color: t.ink2),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('好', style: TextStyle(color: t.flameTxt)),
            ),
          ],
        );
      },
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? t.paper : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
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
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 18, color: t.ink2),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 14, color: t.ink),
              ),
            ),
            Text(trailing, style: TextStyle(fontSize: 13, color: t.ink3)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 18, color: t.ink3),
          ],
        ),
      ),
    );
  }
}
