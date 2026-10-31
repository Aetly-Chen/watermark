import 'package:flutter/material.dart';

/// 设计令牌 —— iOS/Android 唯一的取色入口。
///
/// 数值直接搬自 `watermark-ui-prototype.html` 的 `:root` 与 `[data-theme="dark"]`，
/// 改色只改这里的两处 factory，UI 层一律通过 `AppTokens.of(context)` 取值。
///
/// 为什么不直接用 `ColorScheme`：Material 的语义色（primary / surface / outline…）
/// 只有十几个槽位，装不下原型的 cream / paper / ink / line / flame 这套自建体系；
/// 挂在 `ThemeExtension` 上可以不丢类型安全，也能跟着 ThemeMode 一起插值过渡。
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.cream,
    required this.paper,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.line2,
    required this.flame,
    required this.flameTxt,
    required this.flameSoft,
    required this.media,
    required this.danger,
    required this.onFlame,
  });

  /// 浅色：奶油白 + 炭黑 + 焦橙
  factory AppTokens.light() => const AppTokens(
    cream: Color(0xFFF4EFE5),
    paper: Color(0xFFFFFDF8),
    ink: Color(0xFF1B1A17),
    ink2: Color(0xFF5A544B),
    ink3: Color(0xFF6E6659),
    line: Color(0xFFE3DACA),
    line2: Color(0xFFEFE8DA),
    flame: Color(0xFFC4551B),
    flameTxt: Color(0xFF9E4410),
    flameSoft: Color(0xFFF7E4D4),
    media: Color(0xFF2A2620),
    danger: Color(0xFFA3301F),
    onFlame: Color(0xFFFFFDF8),
  );

  factory AppTokens.dark() => const AppTokens(
    cream: Color(0xFF14120E),
    paper: Color(0xFF1D1A14),
    ink: Color(0xFFF2EDE2),
    ink2: Color(0xFFB4AA9A),
    ink3: Color(0xFF8F8676),
    line: Color(0xFF332D23),
    line2: Color(0xFF272219),
    flame: Color(0xFFE2762F),
    flameTxt: Color(0xFFE8935A),
    flameSoft: Color(0xFF3A2413),
    media: Color(0xFF0B0A08),
    danger: Color(0xFFE0705C),
    onFlame: Color(0xFF14120E),
  );

  /// 页面底色
  final Color cream;

  /// 卡片 / 面板底色
  final Color paper;

  /// 主文字
  final Color ink;

  /// 次要文字、说明
  final Color ink2;

  /// 三级文字、占位
  final Color ink3;

  /// 分隔线、卡片描边
  final Color line;

  final Color line2;

  /// 强调色：主按钮、选中态、进度环
  final Color flame;

  /// 强调色的小字号文本版本（浅色下比 flame 更深，保证对比度）
  final Color flameTxt;

  /// 强调色的浅底
  final Color flameSoft;

  /// 媒体画布（图片/视频预览区）底色，深浅主题都偏暗
  final Color media;

  final Color danger;

  /// 压在 flame 上的文字/图标颜色
  final Color onFlame;

  // ── 圆角与间距：定值，不参与主题插值 ──
  static const double radiusCard = 16;
  static const double radiusButton = 12;
  static const double radiusChip = 999;
  static const double gutter = 16;
  static const double gapS = 8;
  static const double gapM = 12;
  static const double gapL = 20;

  /// 取当前主题的令牌。缺失时抛断言，便于在开发期立刻发现漏注册。
  static AppTokens of(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>();
    assert(tokens != null, 'AppTokens 未注册进 ThemeData.extensions');
    return tokens!;
  }

  @override
  AppTokens copyWith({
    Color? cream,
    Color? paper,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? line,
    Color? line2,
    Color? flame,
    Color? flameTxt,
    Color? flameSoft,
    Color? media,
    Color? danger,
    Color? onFlame,
  }) {
    return AppTokens(
      cream: cream ?? this.cream,
      paper: paper ?? this.paper,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      line: line ?? this.line,
      line2: line2 ?? this.line2,
      flame: flame ?? this.flame,
      flameTxt: flameTxt ?? this.flameTxt,
      flameSoft: flameSoft ?? this.flameSoft,
      media: media ?? this.media,
      danger: danger ?? this.danger,
      onFlame: onFlame ?? this.onFlame,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return AppTokens(
      cream: Color.lerp(cream, other.cream, t)!,
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      line: Color.lerp(line, other.line, t)!,
      line2: Color.lerp(line2, other.line2, t)!,
      flame: Color.lerp(flame, other.flame, t)!,
      flameTxt: Color.lerp(flameTxt, other.flameTxt, t)!,
      flameSoft: Color.lerp(flameSoft, other.flameSoft, t)!,
      media: Color.lerp(media, other.media, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onFlame: Color.lerp(onFlame, other.onFlame, t)!,
    );
  }
}
