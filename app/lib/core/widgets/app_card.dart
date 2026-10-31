import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 基础卡片容器：圆角 16 + 1px 描边 + paper 底。
///
/// 这一层存在的意义是「UI 组件库」只允许从这里出牌 ——
/// 页面里不出现裸 `Container(decoration: …)`，换皮肤时只改这里。
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final radius = BorderRadius.circular(AppTokens.radiusCard);

    return Material(
      color: color ?? t.paper,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: borderColor ?? t.line),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
