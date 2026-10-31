import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_controller.dart';
import 'router/app_router.dart';

/// 根 widget。
///
/// 只做三件事：装配主题、装配路由、把 `ThemeMode` 接上 Riverpod。
/// 任何业务逻辑都不该出现在这里 —— 它必须保持薄，否则测试与深链都会变难。
class WatermarkApp extends ConsumerWidget {
  const WatermarkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeControllerProvider);

    return MaterialApp.router(
      title: '水印工坊',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,

      // 产品只面向中文用户，但保留英文兜底，避免系统语言非中文时回落到 Material 默认英文文案
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
