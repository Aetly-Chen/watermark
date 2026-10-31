import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'theme_mode_store.dart';

part 'theme_mode_controller.g.dart';

/// 主题模式的存储实现。默认走文件；测试里 `overrideWithValue` 换成内存版。
final Provider<ThemeModeStore> themeModeStoreProvider =
    Provider<ThemeModeStore>((ref) => const FileThemeModeStore());

/// 启动时读回的上次选择。
///
/// 单独抽一个 provider，是为了让「读文件」发生在 `runApp` 之前（见 `bootstrap.dart`）——
/// 否则会先按 system 画一帧、再跳到用户选的主题，闪一下很难看。
final Provider<ThemeMode> initialThemeModeProvider = Provider<ThemeMode>(
  (ref) => ThemeMode.system,
);

/// 全局深浅色开关。
///
/// 原型第 08 屏「我的 - 主题模式」对应的就是这个状态；
/// 这里是 Riverpod 与 MaterialApp 打通的最小证据：改 state → 整棵树换主题。
@Riverpod(keepAlive: true)
class ThemeModeController extends _$ThemeModeController {
  @override
  ThemeMode build() => ref.read(initialThemeModeProvider);

  void setMode(ThemeMode mode) {
    if (state == mode) return;
    state = mode;
    final ThemeModeStore store = ref.read(themeModeStoreProvider);
    // 不 await：写盘失败不能卡住 UI，store 内部已经把异常兜住了。
    unawaited(store.write(mode));
  }

  /// 三态轮转，供「跟随系统 → 浅色 → 深色」这种单按钮交互使用
  void cycle() {
    setMode(switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    });
  }
}
