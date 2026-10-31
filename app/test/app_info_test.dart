import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/app_info.dart';

/// 版本号。
///
/// 原来 `profile_page.dart` 三处硬编码 `v0.1.0`，和 `pubspec.yaml` 的
/// `0.1.0+1` 是两个独立事实 —— 改版本时改一处漏两处，界面会安静地报旧版本。
/// 现在统一从 `package_info_plus` 读（源头还是 pubspec），这里测的是
/// 「读不到时不编造」和「空白字段不产生怪字符串」。
void main() {
  group('AppInfo.label', () {
    test('正常版本：v0.1.0', () {
      const info = AppInfo(version: '0.1.0', buildNumber: '1');
      expect(info.label, 'v0.1.0');
      expect(info.buildLabel, '1');
    });

    test('读不到版本时是 v?，不拿 0.0.0 冒充', () {
      const info = AppInfo.unknown();
      expect(info.label, 'v?');
      expect(info.buildLabel, '—');
    });

    test('有版本没构建号：不出现空括号', () {
      const info = AppInfo(version: '2.3.4', buildNumber: '');
      expect(info.label, 'v2.3.4');
      expect(info.buildLabel, '—');
    });
  });
}
