import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 主题模式的持久化接口。
///
/// 只有三个值（system / light / dark），不值得为它引 shared_preferences 那一整套
/// MethodChannel —— App 私有目录里写一行文本就够了。
/// 抽成接口是为了测试能塞内存实现，不必起真机。
abstract interface class ThemeModeStore {
  Future<ThemeMode?> read();

  Future<void> write(ThemeMode mode);
}

/// 内存实现：测试用，也作为默认值（没有持久化时行为不变）。
class MemoryThemeModeStore implements ThemeModeStore {
  MemoryThemeModeStore([this.value]);

  ThemeMode? value;

  /// 记录每次写入，用来断言「同值不重复写」
  final List<ThemeMode> writes = <ThemeMode>[];

  @override
  Future<ThemeMode?> read() async => value;

  @override
  Future<void> write(ThemeMode mode) async {
    value = mode;
    writes.add(mode);
  }
}

/// 文件实现：`<应用支持目录>/theme_mode.txt`，内容就是枚举名。
///
/// `directory` 只为测试注入 —— 单测里没有 platform channel，
/// 拿不到 `getApplicationSupportDirectory()`，就用临时目录替。
class FileThemeModeStore implements ThemeModeStore {
  const FileThemeModeStore({this.directory});

  final Future<Directory> Function()? directory;

  static const String fileName = 'theme_mode.txt';

  Future<File> _file() async {
    final dir = directory != null
        ? await directory!()
        : await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<ThemeMode?> read() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return null;
      return _decode(await f.readAsString());
    } on Object {
      // 读不到（首次启动、目录不可用、测试环境没有 platform channel）就用系统默认。
      return null;
    }
  }

  @override
  Future<void> write(ThemeMode mode) async {
    try {
      final f = await _file();
      await f.writeAsString(mode.name, flush: true);
    } on Object {
      // 存不下就算了 —— 主题记忆失败不该影响用户正在做的事。
    }
  }

  static ThemeMode? _decode(String raw) => switch (raw.trim()) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };
}
