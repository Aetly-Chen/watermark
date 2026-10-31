import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/theme/theme_mode_controller.dart';
import 'package:watermark_remover/core/theme/theme_mode_store.dart';

/// 主题持久化的两条链路分开测：
/// ① 文件 store 真读真写（用临时目录替应用目录）；
/// ② controller 改状态时会写盘、同值不重复写。
/// 不测 `bootstrap`：它内部 runApp，用真机验证更直接。
void main() {
  group('FileThemeModeStore', () {
    late Directory dir;
    late FileThemeModeStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wm_theme_');
      store = FileThemeModeStore(directory: () async => dir);
    });

    tearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('没有文件时返回 null（首次启动）', () async {
      expect(await store.read(), isNull);
    });

    test('写进去再读回来，三态都能还原', () async {
      for (final mode in ThemeMode.values) {
        await store.write(mode);
        expect(await store.read(), mode, reason: '写入 ${mode.name} 后应读回同值');
      }
      // 落盘内容就是枚举名，方便人肉排查
      final raw = await File(
        '${dir.path}${Platform.pathSeparator}${FileThemeModeStore.fileName}',
      ).readAsString();
      expect(raw, 'dark');
    });

    test('文件里是垃圾值时按「没有记录」处理，不崩', () async {
      await File(
        '${dir.path}${Platform.pathSeparator}${FileThemeModeStore.fileName}',
      ).writeAsString('???');
      expect(await store.read(), isNull);
    });
  });

  group('ThemeModeController', () {
    ProviderContainer makeContainer(ThemeMode initial, MemoryThemeModeStore s) {
      final c = ProviderContainer(
        overrides: [
          initialThemeModeProvider.overrideWithValue(initial),
          themeModeStoreProvider.overrideWithValue(s),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('启动值取自 initialThemeModeProvider（即上次选择）', () {
      final store = MemoryThemeModeStore();
      final c = makeContainer(ThemeMode.dark, store);
      expect(c.read(themeModeControllerProvider), ThemeMode.dark);
    });

    test('setMode 会落盘，同值不重复写', () async {
      final store = MemoryThemeModeStore();
      final c = makeContainer(ThemeMode.system, store);
      final notifier = c.read(themeModeControllerProvider.notifier);

      notifier.setMode(ThemeMode.light);
      notifier.setMode(ThemeMode.light);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(themeModeControllerProvider), ThemeMode.light);
      expect(store.writes, <ThemeMode>[ThemeMode.light]);
    });

    test('cycle 按 跟随系统 → 浅色 → 深色 → 跟随系统 轮转', () async {
      final store = MemoryThemeModeStore();
      final c = makeContainer(ThemeMode.system, store);
      final notifier = c.read(themeModeControllerProvider.notifier);

      notifier.cycle();
      expect(c.read(themeModeControllerProvider), ThemeMode.light);
      notifier.cycle();
      expect(c.read(themeModeControllerProvider), ThemeMode.dark);
      notifier.cycle();
      expect(c.read(themeModeControllerProvider), ThemeMode.system);
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, <ThemeMode>[
        ThemeMode.light,
        ThemeMode.dark,
        ThemeMode.system,
      ]);
    });
  });
}
