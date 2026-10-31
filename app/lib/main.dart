import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'bootstrap.dart';
import 'core/app_info.dart';
import 'core/theme/theme_mode_controller.dart';
import 'features/history/application/history_providers.dart';

Future<void> main() async {
  await bootstrap(
    (boot) => ProviderScope(
      // 把 bootstrap 读回来的主题、历史、版本交给 Riverpod，
      // 避免首帧先按默认值画一遍再跳
      overrides: [
        initialThemeModeProvider.overrideWithValue(boot.themeMode),
        initialHistoryProvider.overrideWithValue(boot.history),
        initialAppInfoProvider.overrideWithValue(boot.appInfo),
      ],
      child: const WatermarkApp(),
    ),
  );
}
