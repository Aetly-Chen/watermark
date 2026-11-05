import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 「矩形 / 涂抹 / 橡皮 / 清除」这类工具按钮。
///
/// 图片页和视频页都要这一排，长得必须一样 —— 同一个操作在两屏换位置或换样子，
/// 用户就得重新学一遍。所以从页面里提到 `core/widgets`。
class MaskToolChip extends StatelessWidget {
  const MaskToolChip({
    super.key,
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
