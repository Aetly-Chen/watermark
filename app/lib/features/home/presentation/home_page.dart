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
        titleSpacing: AppTokens.gutter,
        toolbarHeight: 64,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: t.flame,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                Icons.auto_fix_high_rounded,
                size: 18,
                color: t.onFlame,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '水印工坊',
                style: textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
          8,
          AppTokens.gutter,
          28,
        ),
        children: [
          // ── 两个入口（并排双列） ──
          // 副标题是**对外承诺**，只写真的能解的：
          //   图片走 BitmapFactory → JPG / PNG / WEBP / HEIC（HEIC 要 Android 9+，
          //     minSdk 24 的老机器上解不了，但那是少数且会走到「无法解码」提示）；
          //   视频走 MediaExtractor → MP4 / MOV / MKV。
          // 原来这里写着 AVI —— Stagefright 没有 AVI 解析器，选了页面直接报错。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _EntryCard(
                    icon: Icons.image_outlined,
                    title: '图片去水印',
                    subtitle: 'JPG · PNG · WEBP · HEIC',
                    primary: true,
                    onTap: () => context.pushNamed(AppRoutes.imageEditorName),
                  ),
                ),
                const SizedBox(width: AppTokens.gapM),
                Expanded(
                  child: _EntryCard(
                    icon: Icons.videocam_outlined,
                    title: '视频去水印',
                    subtitle: 'MP4 · MOV · MKV · 逐帧修复',
                    onTap: () => context.pushNamed(AppRoutes.videoEditorName),
                  ),
                ),
              ],
            ),
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
          // 历史是真实数据，新装的 App 这里就是空的 —— 留一句极简占位，
          // 避免只剩标题与按钮看着像加载失败。
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text('还没有处理记录', style: textTheme.bodySmall),
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
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: primary ? t.flame : t.flameSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: primary ? t.onFlame : t.flameTxt,
                  size: 21,
                ),
              ),
              const Spacer(),
              Icon(Icons.arrow_outward_rounded, color: t.ink3, size: 18),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15.5,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, height: 1.35, color: t.ink3),
          ),
        ],
      ),
    );
  }
}
