import 'package:flutter/material.dart';

import 'app_tokens.dart';

/// 主题装配。UI 层不直接写颜色，全部走 `AppTokens`。
abstract final class AppTheme {
  /// 主题只装配一次。
  ///
  /// `ColorScheme.fromSeed` 要跑一整套材质配色算法，而 `MaterialApp` 每次重建
  /// （切主题、Riverpod 状态变、热重载）都会同时取 `theme` 和 `darkTheme` ——
  /// 不缓存等于每次白算两遍。切主题时的掉帧有一部分就出在这里。
  static final ThemeData _light = _build(Brightness.light, AppTokens.light());

  static final ThemeData _dark = _build(Brightness.dark, AppTokens.dark());

  static ThemeData light() => _light;

  static ThemeData dark() => _dark;

  static ThemeData _build(Brightness brightness, AppTokens t) {
    // fromSeed 只为补齐 Material 内部还要用的槽位（secondary / surfaceTint 等），
    // 品牌色一律用 copyWith 覆盖成原型的值，避免 Material 调色把焦橙带偏。
    final scheme = ColorScheme.fromSeed(
      seedColor: t.flame,
      brightness: brightness,
    ).copyWith(
      primary: t.flame,
      onPrimary: t.onFlame,
      primaryContainer: t.flameSoft,
      onPrimaryContainer: t.flameTxt,
      surface: t.paper,
      onSurface: t.ink,
      surfaceContainerHighest: t.cream,
      outline: t.line,
      outlineVariant: t.line2,
      error: t.danger,
    );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: t.cream,
      canvasColor: t.paper,
      dividerColor: t.line,
      // 视觉全部由令牌决定，关掉 Material 3 的 surface tint 渐变，避免卡片自己变色
      appBarTheme: AppBarTheme(
        backgroundColor: t.cream,
        foregroundColor: t.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: t.ink,
          letterSpacing: 0.2,
        ),
      ),
      dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
      textTheme: _textTheme(t),
      // 页面切换统一用平台默认，等有具体动效需求再覆盖
      splashFactory: InkSparkle.splashFactory,
      extensions: <ThemeExtension<dynamic>>[t],
    );
  }

  static TextTheme _textTheme(AppTokens t) => TextTheme(
    displaySmall: TextStyle(
      fontSize: 28,
      height: 1.25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      color: t.ink,
    ),
    titleLarge: TextStyle(
      fontSize: 19,
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: t.ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: t.ink,
    ),
    bodyLarge: TextStyle(fontSize: 15, height: 1.6, color: t.ink),
    bodyMedium: TextStyle(fontSize: 13.5, height: 1.55, color: t.ink2),
    bodySmall: TextStyle(fontSize: 12, height: 1.5, color: t.ink3),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: t.ink,
    ),
  );
}
