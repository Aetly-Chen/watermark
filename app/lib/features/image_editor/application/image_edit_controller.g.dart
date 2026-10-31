// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'image_edit_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 02/03 屏的状态机：导入 → 框选 → 生成 Mask → 调引擎 → 出结果。

@ProviderFor(ImageEditController)
final imageEditControllerProvider = ImageEditControllerProvider._();

/// 02/03 屏的状态机：导入 → 框选 → 生成 Mask → 调引擎 → 出结果。
final class ImageEditControllerProvider
    extends $NotifierProvider<ImageEditController, ImageEditState> {
  /// 02/03 屏的状态机：导入 → 框选 → 生成 Mask → 调引擎 → 出结果。
  ImageEditControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'imageEditControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$imageEditControllerHash();

  @$internal
  @override
  ImageEditController create() => ImageEditController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ImageEditState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ImageEditState>(value),
    );
  }
}

String _$imageEditControllerHash() =>
    r'6fcc267b964f6d45e4ab0933f945c6c1f4df4790';

/// 02/03 屏的状态机：导入 → 框选 → 生成 Mask → 调引擎 → 出结果。

abstract class _$ImageEditController extends $Notifier<ImageEditState> {
  ImageEditState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ImageEditState, ImageEditState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ImageEditState, ImageEditState>,
              ImageEditState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
