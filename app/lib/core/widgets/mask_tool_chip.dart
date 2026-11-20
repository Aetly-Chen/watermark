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
    final radius = BorderRadius.circular(AppTokens.radiusButton);
    final fg = selected ? t.flameTxt : t.ink2;

    return Opacity(
      opacity: onTap == null ? 0.42 : 1,
      child: Material(
        color: selected ? t.flameSoft : t.paper,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: t.hoverTint,
          focusColor: t.hoverTint,
          splashColor: t.flame.withValues(alpha: 0.14),
          highlightColor: t.flame.withValues(alpha: 0.08),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: selected ? t.flame : t.line,
                width: selected ? 1.2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
