import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/app_info.dart';
import 'core/diagnostics/frame_probe.dart';
import 'core/theme/theme_mode_store.dart';
import 'features/history/domain/history_item.dart';
import 'features/history/infrastructure/history_store.dart';

/// `runApp` 之前必须就绪的东西。主题和历史读盘、版本要问系统，所以要有个地方装。
///
/// 全都在首帧之前取回：晚一步的话，主题会先按 system 画一帧再跳、
/// 历史会先空一屏再被填满、版本会先显示 `v?` 再变成 `v0.1.0`，冷启动都看得见。
@immutable
class BootData {
  const BootData({
    required this.themeMode,
    required this.history,
    required this.appInfo,
  });

  final ThemeMode themeMode;
  final List<HistoryItem> history;
  final AppInfo appInfo;
}

/// 应用启动的唯一入口逻辑。
///
/// 放在 `main()` 之外是为了：测试可以直接构造 widget 树，不必跑这段全局钩子。
Future<void> bootstrap(Widget Function(BootData boot) appBuilder) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 体感卡顿只能靠帧耗时判断（adb 侧在 Impeller 下拿不到数据）。
  // 默认是空操作，只有带 --dart-define=WM_FRAME_PROBE=true 构建时才打日志。
  FrameProbe.install();

  // 构建期异常：debug 打到控制台；release 先兜住，后续接崩溃上报
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
  };

  // 异步未捕获异常（Future 里抛的），不接住会静默丢失
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[uncaught] $error\n$stack');
    return true;
  };

  // 三件事并行发起，总耗时 ≈ 最慢的那个，而不是三个相加。
  final themeFuture = _restore<ThemeMode>(
    label: '主题偏好',
    load: () async =>
        await const FileThemeModeStore().read() ?? ThemeMode.system,
    fallback: ThemeMode.system,
  );
  final historyFuture = _restore<List<HistoryItem>>(
    label: '历史记录',
    load: () => const FileHistoryStore().read(),
    fallback: const <HistoryItem>[],
  );
  final appInfoFuture = _restore<AppInfo>(
    label: '版本信息',
    load: readAppInfo,
    fallback: const AppInfo.unknown(),
  );

  runApp(
    appBuilder(
      BootData(
        themeMode: await themeFuture,
        history: await historyFuture,
        appInfo: await appInfoFuture,
      ),
    ),
  );
}

/// 读盘带超时，并把真实耗时打进日志。
///
/// 第一版给主题读取设了 300 ms 超时，而冷启动首次 `getApplicationSupportDirectory()`
/// 就要几百毫秒 —— 于是每次都超时、每次都回落默认值，现象只是「设置没生效」，
/// 代码看着完全正确。**静默兜底的分支必须在日志里留字**，否则失败和「没做」长得一样。
Future<T> _restore<T>({
  required String label,
  required Future<T> Function() load,
  required T fallback,
}) async {
  final watch = Stopwatch()..start();
  try {
    final value = await load().timeout(const Duration(milliseconds: 1500));
    watch.stop();
    debugPrint('[boot] $label 就绪 耗时=${watch.elapsedMilliseconds}ms');
    return value;
  } on TimeoutException {
    debugPrint('[boot] $label 读取超时（>1500ms），用默认值启动');
  } on Object catch (error) {
    debugPrint('[boot] $label 读取失败（$error），用默认值启动');
  }
  return fallback;
}
