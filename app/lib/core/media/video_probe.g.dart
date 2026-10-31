// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_probe.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(videoProbe)
final videoProbeProvider = VideoProbeProvider._();

final class VideoProbeProvider
    extends $FunctionalProvider<VideoProbe, VideoProbe, VideoProbe>
    with $Provider<VideoProbe> {
  VideoProbeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'videoProbeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$videoProbeHash();

  @$internal
  @override
  $ProviderElement<VideoProbe> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  VideoProbe create(Ref ref) {
    return videoProbe(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(VideoProbe value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<VideoProbe>(value),
    );
  }
}

String _$videoProbeHash() => r'dcd3b6a7156d857926c324089ea94f1331e04407';
