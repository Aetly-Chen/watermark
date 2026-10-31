// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_basic_image_processor.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// 全局引擎实例。将来加 [ProcessingMode.localAi] 时在这里按 mode 分发即可，
/// UI 只依赖 `WatermarkProcessor` 抽象，不需要知道具体实现。

@ProviderFor(watermarkProcessor)
final watermarkProcessorProvider = WatermarkProcessorProvider._();

/// 全局引擎实例。将来加 [ProcessingMode.localAi] 时在这里按 mode 分发即可，
/// UI 只依赖 `WatermarkProcessor` 抽象，不需要知道具体实现。

final class WatermarkProcessorProvider
    extends
        $FunctionalProvider<
          WatermarkProcessor,
          WatermarkProcessor,
          WatermarkProcessor
        >
    with $Provider<WatermarkProcessor> {
  /// 全局引擎实例。将来加 [ProcessingMode.localAi] 时在这里按 mode 分发即可，
  /// UI 只依赖 `WatermarkProcessor` 抽象，不需要知道具体实现。
  WatermarkProcessorProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'watermarkProcessorProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$watermarkProcessorHash();

  @$internal
  @override
  $ProviderElement<WatermarkProcessor> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  WatermarkProcessor create(Ref ref) {
    return watermarkProcessor(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WatermarkProcessor value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WatermarkProcessor>(value),
    );
  }
}

String _$watermarkProcessorHash() =>
    r'd06865b67c00db689f20f8bd3a6f06673820a094';
