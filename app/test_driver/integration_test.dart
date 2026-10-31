import 'package:integration_test/integration_test_driver.dart';

/// 用 `flutter drive` 跑集成测试的驱动入口。
///
/// 相比 `flutter test integration_test/...`，drive 跑完不会卸载应用，
/// 所以测试过程中落在应用 cache 里的产物还能用 `adb run-as` 取出来做人工比对。
Future<void> main() => integrationDriver();
