import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_card.dart';
import '../../history/application/history_providers.dart';
import '../../history/presentation/widgets/history_tile.dart';

/// 01 首页。
///
/// 这一屏的作用是把 Riverpod 和 go_router 都跑通一遍：
/// 两个入口卡走 `context.pushNamed`，最近处理列表走 `ref.watch` 的派生 provider。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppTokens.of(context);
    final recent = ref.watch(historyItemsProvider).take(2).toList();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        toolbarHeight: 70,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('水印工坊', style: textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              '本地去水印 · 文件不必上传',
              style: textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '我的',
            onPressed: () => context.go(AppRoutes.profile),
            icon: Icon(Icons.settings_outlined, color: t.ink2),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppTokens.gutter,
          4,
          AppTokens.gutter,
          28,
        ),
        children: [
          // ── 说明卡 ──
          AppCard(
            color: t.flameSoft,
            borderColor: t.flameSoft,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 16, color: t.flameTxt),
                    const SizedBox(width: 6),
                    Text(
                      '简单三步',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: t.flameTxt,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '选素材 → 涂抹水印 → 本机修复。全程不联网，导出直接进相册。',
                  style: textTheme.bodyMedium?.copyWith(color: t.flameTxt),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.gapM),

          // ── 两个入口 ──
          // 副标题是**对外承诺**，只写真的能解的：
          //   图片走 BitmapFactory → JPG / PNG / WEBP / HEIC（HEIC 要 Android 9+，
          //     minSdk 24 的老机器上解不了，但那是少数且会走到「无法解码」提示）；
          //   视频走 MediaExtractor → MP4 / MOV / MKV。
          // 原来这里写着 AVI —— Stagefright 没有 AVI 解析器，选了页面直接报错。
          _EntryCard(
            icon: Icons.image_outlined,
            title: '图片去水印',
            subtitle: 'JPG · PNG · WEBP · HEIC',
            onTap: () => context.pushNamed(AppRoutes.imageEditorName),
          ),
          const SizedBox(height: AppTokens.gapM),
          _EntryCard(
            icon: Icons.videocam_outlined,
            title: '视频去水印',
            subtitle: 'MP4 · MOV · MKV · 逐帧修复',
            onTap: () => context.pushNamed(AppRoutes.videoEditorName),
          ),

          // ── 最近处理 ──
          const SizedBox(height: AppTokens.gapL),
          Row(
            children: [
              Text('最近处理', style: textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: () => context.go(AppRoutes.history),
                style: TextButton.styleFrom(
                  foregroundColor: t.flameTxt,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('全部记录'),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.gapS),
          // 历史是真实数据，新装的 App 这里就是空的 —— 得说一句，
          // 否则只剩一个「最近处理 / 全部记录」的标题，看着像加载失败。
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                '还没有处理记录。上面选一个入口开始，成品记录会出现在这里。',
                style: textTheme.bodySmall,
              ),
            ),
          for (final item in recent) ...[
            HistoryTile(
              item: item,
              onTap: () => context.pushNamed(
                AppRoutes.historyDetailName,
                pathParameters: {'id': item.id},
              ),
            ),
            const SizedBox(height: AppTokens.gapS),
          ],
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: t.flameSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: t.flameTxt, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(subtitle, style: TextStyle(fontSize: 12, color: t.ink3)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: t.ink3, size: 20),
        ],
      ),
    );
  }
}
