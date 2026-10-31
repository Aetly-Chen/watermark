// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_mode_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 全局深浅色开关。
///
/// 原型第 08 屏「我的 - 主题模式」对应的就是这个状态；
/// 这里是 Riverpod 与 MaterialApp 打通的最小证据：改 state → 整棵树换主题。

@ProviderFor(ThemeModeController)
final themeModeControllerProvider = ThemeModeControllerProvider._();

/// 全局深浅色开关。
///
/// 原型第 08 屏「我的 - 主题模式」对应的就是这个状态；
/// 这里是 Riverpod 与 MaterialApp 打通的最小证据：改 state → 整棵树换主题。
final class ThemeModeControllerProvider
    extends $NotifierProvider<ThemeModeController, ThemeMode> {
  /// 全局深浅色开关。
  ///
  /// 原型第 08 屏「我的 - 主题模式」对应的就是这个状态；
  /// 这里是 Riverpod 与 MaterialApp 打通的最小证据：改 state → 整棵树换主题。
  ThemeModeControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'themeModeControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$themeModeControllerHash();

  @$internal
  @override
  ThemeModeController create() => ThemeModeController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ThemeMode value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ThemeMode>(value),
    );
  }
}

String _$themeModeControllerHash() =>
    r'a443822c5d4ee348f67fb9ce3572a9492317c921';

/// 全局深浅色开关。
///
/// 原型第 08 屏「我的 - 主题模式」对应的就是这个状态；
/// 这里是 Riverpod 与 MaterialApp 打通的最小证据：改 state → 整棵树换主题。

abstract class _$ThemeModeController extends $Notifier<ThemeMode> {
  ThemeMode build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ThemeMode, ThemeMode>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ThemeMode, ThemeMode>,
              ThemeMode,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
