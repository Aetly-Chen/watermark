import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum AppButtonVariant {
  /// 焦橙实底：一屏只应出现一个
  primary,

  /// 白底描边：次要操作
  secondary,

  /// 纯文字 / 图标
  ghost,
}

/// 主按钮。高度、圆角、配色统一从这里出，避免各页面各写一套。
class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    super.key,
    this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.primary,
    this.expand = true,
    this.height = 52,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonVariant variant;
  final bool expand;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(AppTokens.radiusButton);

    final (bg, fg, border) = switch (variant) {
      AppButtonVariant.primary => (t.flame, t.onFlame, Colors.transparent),
      AppButtonVariant.secondary => (t.paper, t.ink, t.line),
      AppButtonVariant.ghost => (Colors.transparent, t.flameTxt, Colors.transparent),
    };

    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg),
        ),
      ],
    );

    final button = Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: bg,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          child: Ink(
            height: height,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: border),
            ),
            child: Center(child: content),
          ),
        ),
      ),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
