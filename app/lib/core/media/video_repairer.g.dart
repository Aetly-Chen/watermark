// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_repairer.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(videoRepairer)
final videoRepairerProvider = VideoRepairerProvider._();

final class VideoRepairerProvider
    extends $FunctionalProvider<VideoRepairer, VideoRepairer, VideoRepairer>
    with $Provider<VideoRepairer> {
  VideoRepairerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'videoRepairerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$videoRepairerHash();

  @$internal
  @override
  $ProviderElement<VideoRepairer> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  VideoRepairer create(Ref ref) {
    return videoRepairer(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(VideoRepairer value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<VideoRepairer>(value),
    );
  }
}

String _$videoRepairerHash() => r'404cfe8b7bd5ede8ce729d9783cc112900d62034';
