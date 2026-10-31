import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 应用版本信息。
///
/// **唯一来源是 `pubspec.yaml` 的 `version:`** —— 它经 Gradle 写进
/// AndroidManifest，再由 `package_info_plus` 从系统读回来。
///
/// 为什么不在界面里写死：`profile_page.dart` 原来三处硬编码 `v0.1.0`，
/// 和 pubspec 的 `0.1.0+1` 是两个独立事实。改版本时改一处忘两处，
/// 界面会安静地报旧版本 —— 这种错没人会注意到，直到用户报上来。
@immutable
class AppInfo {
  const AppInfo({required this.version, required this.buildNumber});

  /// 读不到时的占位。不拿 `0.0.0` 冒充真实版本。
  const AppInfo.unknown() : version = '', buildNumber = '';

  AppInfo.fromPlatformInfo(PackageInfo info)
    : version = info.version,
      buildNumber = info.buildNumber;

  final String version;
  final String buildNumber;

  /// `v0.1.0`。读不到时是 `v?` —— 宁可露出生疏，也不编一个版本号。
  String get label => version.isEmpty ? 'v?' : 'v$version';

  /// 构建号（`version:` 里的 `+1`），用于「关于」里区分同一版本的多次构建。
  String get buildLabel => buildNumber.isEmpty ? '—' : buildNumber;
}

/// 启动时读回，`bootstrap` 里注入；默认占位，所以测试不用管它。
final Provider<AppInfo> initialAppInfoProvider = Provider<AppInfo>(
  (ref) => const AppInfo.unknown(),
);

/// 界面读这个。名字不带 `initial` —— 它回答的是「现在是什么版本」，
/// 而不是「启动时读到了什么」。
final Provider<AppInfo> appInfoProvider = Provider<AppInfo>(
  (ref) => ref.watch(initialAppInfoProvider),
);

/// 读原生版本。**失败不抛** —— 读版本号失败不该把 App 拦在启动页。
Future<AppInfo> readAppInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    debugPrint('[boot] 版本 ${info.version}+${info.buildNumber}');
    return AppInfo.fromPlatformInfo(info);
  } on Object catch (error) {
    debugPrint('[boot] 读版本失败（$error），界面显示 v?');
    return const AppInfo.unknown();
  }
}
