import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/features/image_editor/application/image_edit_controller.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';

/// 图片控制器的失败路径。
///
/// 这一组是被自己的代码读出来的：`loadSample()` 原来**完全没有 try**，
/// asset 缺失或解码失败会变成一条 uncaught async error —— 只进
/// `PlatformDispatcher.onError` 的日志，界面上什么都不发生。
/// `pickFromGallery()` 只捕 `PlatformException`，`readAsBytes` 失败同样静默。
///
/// 「点了没反应且没有提示」是这一整轮在清的那类问题：不是崩溃、不是错乱，
/// 就是**什么都不发生**，用户只能以为 App 卡了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer make() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('示例图读不到时，状态里要有中文提示（不是静默）', () async {
    // 让 asset 通道返回 null → rootBundle.load 抛「Unable to load asset」
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (message) async => null);
    addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));

    final container = make();
    await container.read(imageEditControllerProvider.notifier).loadSample();

    final state = container.read(imageEditControllerProvider);
    expect(state.error, isNotNull, reason: '失败必须可见');
    expect(state.error, contains('示例图加载失败'));
    // 不把 "Unable to load asset" 这种英文怼给用户
    expect(state.error, isNot(contains('Unable to load')));
    expect(state.source, isNull, reason: '没读到就不该有图');
  });

  test('asset 正常时不会误报错误', () async {
    final container = make();
    await container.read(imageEditControllerProvider.notifier).loadSample();

    final state = container.read(imageEditControllerProvider);
    expect(state.error, isNull);
    expect(state.source, isNotNull);
    expect(state.sourceName, 'cafe.jpg');
    expect(state.imageSize, isNotNull);
  });

  test('修复时的兜底 catch 只给中文，不把异常原文糊到界面', () async {
    final container = make();
    final controller = container.read(imageEditControllerProvider.notifier);
    await controller.loadSample();
    controller.setDraft(const MaskDraft(rect: Rect.fromLTWH(0.25, 0.25, 0.5, 0.5)));

    // 测试环境里没有 path_provider 插件 → `getTemporaryDirectory()` 抛
    // `MissingPluginException(... No implementation found for method ...)`。
    // 这正是兜底分支会收到的形状：**异常原文全是英文 + 内部细节**。
    await controller.run();

    final state = container.read(imageEditControllerProvider);
    expect(state.error, contains('处理失败'), reason: '要给一句人话');
    expect(
      state.error,
      isNot(contains('MissingPluginException')),
      reason: '异常类型名不该出现在用户文案里',
    );
    expect(state.busy, isFalse, reason: '失败后按钮必须能再点，不能一直转');
  });

  test('打开相册被拒：给的是能照做的中文，不是英文 code', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async => throw PlatformException(
        code: 'photo_access_denied',
        message: 'photo_access_denied',
      ),
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/image_picker'),
        null,
      ),
    );

    final container = make();
    await container.read(imageEditControllerProvider.notifier).pickFromGallery();

    final state = container.read(imageEditControllerProvider);
    // ⚠ 断言要精确到分支文案：如果 mock 没生效，会走进 `on Object` 那条
    // 「打不开这张图」，此时「不含 photo_access_denied」**也会通过** —— 假通过。
    expect(state.error, contains('打不开相册'));
    expect(state.error, isNot(contains('photo_access_denied')));
  });
}
