// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_edit_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(VideoEditController)
final videoEditControllerProvider = VideoEditControllerProvider._();

final class VideoEditControllerProvider
    extends $NotifierProvider<VideoEditController, VideoEditState> {
  VideoEditControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'videoEditControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$videoEditControllerHash();

  @$internal
  @override
  VideoEditController create() => VideoEditController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(VideoEditState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<VideoEditState>(value),
    );
  }
}

String _$videoEditControllerHash() =>
    r'9115d536157029374934bff4d669149797db6366';

abstract class _$VideoEditController extends $Notifier<VideoEditState> {
  VideoEditState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<VideoEditState, VideoEditState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<VideoEditState, VideoEditState>,
              VideoEditState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
